import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import '../config/app_env.dart';
import 'delivery_service.dart';
import 'notification_dispatch_service.dart';
import 'restaurant_share_service.dart';
import 'server_clock_service.dart';
import '../shared/models/menu_item.dart';
import '../shared/models/order.dart';

class DeliveryConfirmationResult {
  final bool success;
  final String message;
  final String? status;

  const DeliveryConfirmationResult({
    required this.success,
    required this.message,
    this.status,
  });
}

class OrderActionResult {
  final bool success;
  final String message;
  final String? status;
  final Map<String, dynamic> data;

  const OrderActionResult({
    required this.success,
    required this.message,
    this.status,
    this.data = const <String, dynamic>{},
  });
}

class OrderService {
  final SupabaseClient _supabase = Supabase.instance.client;
  final RestaurantShareService _restaurantShareService =
      RestaurantShareService();
  final NotificationDispatchService _notificationDispatch =
      NotificationDispatchService.instance;
  final DeliveryService _deliveryService = DeliveryService();
  DateTime? _lastPreparationSweepAt;

  String _orderRef(String orderId) {
    final compact = orderId.replaceAll('-', '').toUpperCase();
    final short = compact.length >= 6 ? compact.substring(0, 6) : compact;
    return '#$short';
  }

  int _estimatedPreparationMinutes(Map<String, dynamic> orderRow) {
    final direct = (orderRow['estimated_delivery_time'] as num?)?.toInt();
    if (direct != null && direct > 0) return direct;
    final restaurant = (orderRow['restaurants'] as Map?)
        ?.cast<String, dynamic>();
    final nested = (restaurant?['estimated_delivery_time'] as num?)?.toInt();
    if (nested != null && nested > 0) return nested;
    return 25;
  }

  bool _isMissingAtomicWalletCheckoutRpc(PostgrestException error) {
    final message = error.message.toLowerCase();
    if (!message.contains('create_order_transactional_with_wallet_payment')) {
      return false;
    }
    return message.contains('could not find the function') ||
        message.contains('does not exist') ||
        message.contains('undefined function');
  }

  String _mapCreateOrderErrorMessage(String raw) {
    final normalized = raw.trim().toLowerCase();
    if (normalized.contains('insufficient_available_balance') ||
        normalized.contains('insufficient_balance')) {
      return 'Saldo insuficiente na carteira para concluir o pedido.';
    }
    if (normalized.contains('wallet_not_found')) {
      return 'Carteira nao encontrada para esta conta.';
    }
    if (normalized.contains('order_creation_failed')) {
      return 'Nao foi possivel criar o pedido agora. Tente novamente.';
    }
    return raw;
  }

  Future<void> _notifyImmediateRestaurantPaidOrder(Order order) async {
    try {
      final title = 'Novo pedido pago';
      final restaurantName =
          order.restaurantName?.trim().isNotEmpty == true
              ? order.restaurantName!.trim()
              : 'seu restaurante';
      final body =
          'O pedido pago de $restaurantName ja esta pronto para aceite do restaurante.';

      final response = await _supabase.functions.invoke(
        'order-critical-notification-control',
        body: {
          'order_id': order.id,
          'target_role': 'restaurant_owner',
          'type': 'NEW_PAID_ORDER',
          'title': title,
          'body': body,
          'action': 'OPEN_ORDER',
          'priority': 'HIGH',
          'channel': 'restaurant',
          'data': {
            'order_id': order.id,
            'order_ref': _orderRef(order.id),
          },
          'metadata': {
            'order_id': order.id,
            'restaurant_id': order.restaurantId,
            'restaurant_name': order.restaurantName,
            'dispatch_source': 'client_atomic_wallet_checkout',
          },
        },
      );

      final data = response.data;
      if (response.status < 200 || response.status >= 300) {
        throw StateError(
          'order-critical-notification-control failed: ${response.data}',
        );
      }
      if (data is Map && data['success'] == false) {
        throw StateError(
          'order-critical-notification-control returned success=false',
        );
      }
    } catch (error) {
      debugPrint(
        'Immediate restaurant paid-order notification failed for ${order.id}: '
        '$error',
      );
    }
  }

  DateTime? _preparationStartedAt(Map<String, dynamic> orderRow) {
    final direct =
        (orderRow['preparing_at'] ?? orderRow['preparation_started_at'])
            ?.toString();
    if (direct != null && direct.isNotEmpty) {
      final parsed = DateTime.tryParse(direct);
      if (parsed != null) return parsed;
    }

    final paymentSplits = orderRow['payment_splits'];
    if (paymentSplits is Map) {
      final nested = paymentSplits['restaurant_confirmed_at']?.toString();
      if (nested != null && nested.isNotEmpty) {
        final parsed = DateTime.tryParse(nested);
        if (parsed != null) return parsed;
      }
    } else if (paymentSplits is List && paymentSplits.isNotEmpty) {
      final first = paymentSplits.first;
      if (first is Map) {
        final nested = first['restaurant_confirmed_at']?.toString();
        if (nested != null && nested.isNotEmpty) {
          final parsed = DateTime.tryParse(nested);
          if (parsed != null) return parsed;
        }
      }
    }

    final updated = orderRow['updated_at']?.toString();
    if (updated != null && updated.isNotEmpty) {
      final parsed = DateTime.tryParse(updated);
      if (parsed != null) return parsed;
    }

    final created = orderRow['created_at']?.toString();
    if (created != null && created.isNotEmpty) {
      return DateTime.tryParse(created);
    }
    return null;
  }

  Future<void> _triggerPreparationSweep({bool force = false}) async {
    await ServerClockService.instance.sync();
    final now = ServerClockService.instance.now();
    if (!force &&
        _lastPreparationSweepAt != null &&
        now.difference(_lastPreparationSweepAt!) <
            const Duration(seconds: 15)) {
      return;
    }

    try {
      await _supabase.rpc('process_preparing_orders');
      await _supabase.rpc('process_restaurant_confirmation_timeouts');
      await _supabase.rpc('process_stuck_orders');
      _lastPreparationSweepAt = now;
    } catch (e) {
      debugPrint('Erro ao processar progresso automÃ¡tico dos pedidos: $e');
    }
  }

  Future<void> _ensureOrderPreparationState(
    Map<String, dynamic> orderRow,
  ) async {
    final orderId = orderRow['id']?.toString();
    if (orderId == null || orderId.isEmpty) return;

    final status = orderRow['status']?.toString().toLowerCase();
    if (status != 'accepted' && status != 'preparing') return;

    final statusStartedAt = _preparationStartedAt(orderRow);
    if (statusStartedAt == null) return;

    final prepMinutes = _estimatedPreparationMinutes(orderRow);
    final readyAt = statusStartedAt.add(Duration(minutes: prepMinutes));
    await ServerClockService.instance.sync();
    final now = ServerClockService.instance.now();

    if (readyAt.isBefore(now) || readyAt.isAtSameMomentAs(now)) {
      if (status != 'ready') {
        await updateOrderStatus(orderId, 'ready');
      }
      return;
    }

    final elapsedMinutes = now.difference(statusStartedAt).inMinutes;
    if (elapsedMinutes >= 1 && status == 'accepted') {
      await updateOrderStatus(orderId, 'preparing');
    }
  }

  Future<void> _hydrateOrderCourierAssignment(
    Map<String, dynamic> orderRow, {
    bool persist = false,
  }) async {
    final currentCourierId = orderRow['courier_id']?.toString().trim() ?? '';
    if (currentCourierId.isNotEmpty) return;

    final orderId = orderRow['id']?.toString().trim() ?? '';
    if (orderId.isEmpty) return;

    try {
      final delivery = await _supabase
          .from('deliveries')
          .select('courier_id')
          .eq('order_id', orderId)
          .order('updated_at', ascending: false)
          .limit(1)
          .maybeSingle();
      final fallbackCourierId = delivery?['courier_id']?.toString().trim() ?? '';
      if (fallbackCourierId.isEmpty) return;

      orderRow['courier_id'] = fallbackCourierId;
      if (!persist) return;

      await _supabase
          .from('orders')
          .update({
            'courier_id': fallbackCourierId,
            'updated_at': ServerClockService.instance.nowIso8601Utc(),
          })
          .eq('id', orderId);
    } catch (e) {
      debugPrint('Erro ao hidratar courier_id do pedido $orderId: $e');
    }
  }

  Future<void> _persistOrderComboMetadata(
    String orderId,
    Map<String, dynamic>? combo,
  ) async {
    if (combo == null) return;
    try {
      await ServerClockService.instance.sync();
      final updates = <String, dynamic>{
        'combo_id': combo['id']?.toString(),
        'combo_title': combo['title']?.toString(),
        'combo_discount_percentage': (combo['discount_percentage'] as num?)
            ?.toDouble(),
        'combo_discount_amount':
            (combo['discount_amount'] as num?)?.toDouble() ?? 0,
        'updated_at': ServerClockService.instance.nowIso8601Utc(),
      };
      await _supabase.from('orders').update(updates).eq('id', orderId);
    } catch (e) {
      debugPrint('Erro ao persistir metadados do combo: $e');
    }
  }

  Future<Map<String, String>?> _authHeaders() async {
    final token = _supabase.auth.currentSession?.accessToken;
    final headers = <String, String>{};
    if (token != null && token.isNotEmpty) {
      headers['Authorization'] = 'Bearer $token';
    }
    final anonKey = AppEnv.supabaseAnonKey;
    if (anonKey.isNotEmpty) {
      headers['apikey'] = anonKey;
    }
    return headers.isEmpty ? null : headers;
  }

  Future<void> _notifyStatusChangePush({
    required String orderId,
    required String status,
    required Map<String, dynamic> updatedOrder,
  }) async {
    try {
      final orderDetails = await _supabase
          .from('orders')
          .select('client_id, customer_id, restaurant_id, delivery_type')
          .eq('id', orderId)
          .maybeSingle();
      if (orderDetails == null) return;

      final clientId = (orderDetails['client_id'] ?? orderDetails['customer_id'])
          ?.toString()
          .trim();
      if (clientId == null || clientId.isEmpty) return;

      final restaurantId = orderDetails['restaurant_id']?.toString().trim();
      String restaurantName = 'o restaurante';
      if (restaurantId != null && restaurantId.isNotEmpty) {
        final restaurant = await _supabase
            .from('restaurants')
            .select('name')
            .eq('id', restaurantId)
            .maybeSingle();
        final name = restaurant?['name']?.toString().trim();
        if (name != null && name.isNotEmpty) {
          restaurantName = name;
        }
      }

      final orderRef = _orderRef(orderId);
      final deliveryType =
          orderDetails['delivery_type']?.toString().trim().toLowerCase();
      final deliveryFee =
          (updatedOrder['delivery_fee'] as num?)?.toDouble() ?? 0.0;
      final isPickup = deliveryType == 'pickup' || deliveryFee <= 0;

      switch (status) {
        case 'accepted':
          await _notificationDispatch.sendToUser(
            userId: clientId,
            type: 'ORDER_ACCEPTED',
            title: 'Pedido confirmado',
            body:
                '$restaurantName confirmou o pedido $orderRef e ja vai avancar com a preparacao.',
            action: 'OPEN_ORDER',
            entityId: orderId,
            priority: 'HIGH',
            channel: 'order',
            data: {
              'order_id': orderId,
              'order_ref': orderRef,
              'restaurant_name': restaurantName,
            },
            metadata: {
              'order_id': orderId,
              'order_ref': orderRef,
              'restaurant_name': restaurantName,
            },
          );
          break;
        case 'preparing':
          await _notificationDispatch.sendToUser(
            userId: clientId,
            type: 'ORDER_PREPARING',
            title: 'Pedido em preparo',
            body: '$restaurantName ja esta a preparar o teu pedido $orderRef.',
            action: 'OPEN_ORDER',
            entityId: orderId,
            priority: 'HIGH',
            channel: 'order',
            data: {
              'order_id': orderId,
              'order_ref': orderRef,
              'restaurant_name': restaurantName,
            },
            metadata: {
              'order_id': orderId,
              'order_ref': orderRef,
              'restaurant_name': restaurantName,
            },
          );
          break;
        case 'ready':
          await _notificationDispatch.sendToUser(
            userId: clientId,
            type: 'ORDER_READY',
            title: isPickup ? 'Pedido pronto para retirada' : 'Pedido pronto',
            body: isPickup
                ? '$restaurantName terminou o pedido $orderRef. Ja podes levantar.'
                : '$restaurantName terminou o pedido $orderRef. Agora segue para entrega.',
            action: 'OPEN_ORDER',
            entityId: orderId,
            priority: 'HIGH',
            channel: isPickup ? 'pickup' : 'delivery',
            data: {
              'order_id': orderId,
              'order_ref': orderRef,
              'restaurant_name': restaurantName,
            },
            metadata: {
              'order_id': orderId,
              'order_ref': orderRef,
              'restaurant_name': restaurantName,
            },
          );
          break;
        default:
          break;
      }
    } catch (error) {
      debugPrint('OrderService._notifyStatusChangePush error: $error');
    }
  }

  Future<Map<String, dynamic>?> _invokeFunctionDirect(
    String functionName, {
    Map<String, dynamic>? body,
  }) async {
    final headers = await _authHeaders();
    final supabaseUrl = AppEnv.supabaseUrl;
    if (headers == null || supabaseUrl.isEmpty) return null;

    final response = await http.post(
      Uri.parse('$supabaseUrl/functions/v1/$functionName'),
      headers: {...headers, 'Content-Type': 'application/json'},
      body: jsonEncode(body ?? const <String, dynamic>{}),
    );

    if (response.body.trim().isEmpty) {
      return <String, dynamic>{
        'success': response.statusCode >= 200 && response.statusCode < 300,
      };
    }

    final decoded = jsonDecode(response.body);
    if (decoded is Map) {
      return Map<String, dynamic>.from(decoded);
    }

    return <String, dynamic>{
      'success': response.statusCode >= 200 && response.statusCode < 300,
      'data': decoded,
    };
  }

  /// Normaliza e valida itens para criaï¿½ï¿½o transacional do pedido.
  static List<Map<String, dynamic>> normalizeOrderItems(
    List<Map<String, dynamic>> items,
  ) {
    if (items.isEmpty) {
      throw const FormatException('items nï¿½o pode estar vazio');
    }

    return items
        .map((item) {
          final menuItemId = item['menu_item_id'];
          final quantity = item['quantity'];
          final unitPrice = item['unit_price'];
          final subtotal = item['subtotal'];

          if (menuItemId == null || menuItemId.toString().isEmpty) {
            throw const FormatException('menu_item_id obrigatï¿½rio');
          }

          final qty = (quantity as num?)?.toInt();
          if (qty == null || qty <= 0) {
            throw const FormatException('quantity deve ser maior que zero');
          }

          final unit = (unitPrice as num?)?.toDouble();
          final sub = (subtotal as num?)?.toDouble();
          if (unit == null || sub == null || unit <= 0 || sub <= 0) {
            throw const FormatException(
              'unit_price e subtotal devem ser vÃ¡lidos',
            );
          }

          return {
            'menu_item_id': menuItemId.toString(),
            'quantity': qty,
            'unit_price': unit,
            'subtotal': sub,
          };
        })
        .toList(growable: false);
  }

  /// Criar novo pedido de forma atï¿½mica via RPC.
  Future<Order?> createOrder({
    required String restaurantId,
    required String deliveryAddress,
    required double totalAmount,
    required double deliveryFee,
    required String paymentMethod,
    required List<Map<String, dynamic>> items,
    bool processWalletPayment = false,
    String deliveryType = 'delivery',
    DateTime? scheduledFor,
    String? groupCode,
    Map<String, dynamic>? combo,
    double? deliveryLatitude,
    double? deliveryLongitude,
  }) async {
    try {
      final user = _supabase.auth.currentUser;
      if (user == null) {
        throw Exception('Usuï¿½rio nï¿½o autenticado');
      }

      final normalizedItems = normalizeOrderItems(items);
      final normalizedPaymentMethod = paymentMethod.trim().toLowerCase();
      final useAtomicWalletCheckout =
          processWalletPayment && normalizedPaymentMethod == 'wallet';
      final rpcName = useAtomicWalletCheckout
          ? 'create_order_transactional_with_wallet_payment'
          : 'create_order_transactional';
      final params = {
        'p_restaurant_id': restaurantId,
        'p_delivery_address': deliveryAddress,
        'p_total_amount': totalAmount,
        'p_delivery_fee': deliveryFee,
        'p_payment_method': normalizedPaymentMethod,
        'p_items': normalizedItems,
        'p_scheduled_for': scheduledFor?.toIso8601String(),
        'p_group_code': groupCode,
        'p_delivery_type': deliveryType,
        'p_delivery_latitude': deliveryLatitude,
        'p_delivery_longitude': deliveryLongitude,
      };

      dynamic response;
      try {
        response = await _supabase.rpc(rpcName, params: params);
      } on PostgrestException catch (rpcError) {
        if (useAtomicWalletCheckout &&
            _isMissingAtomicWalletCheckoutRpc(rpcError)) {
          debugPrint(
            'create_order_transactional_with_wallet_payment nao encontrado. '
            'A usar fallback create_order_transactional.',
          );
          response = await _supabase.rpc(
            'create_order_transactional',
            params: params,
          );
        } else {
          rethrow;
        }
      }

      if (response == null) {
        throw Exception('order_creation_failed');
      }

      final order = Order.fromMap(Map<String, dynamic>.from(response as Map));
      await _persistOrderComboMetadata(order.id, combo);
      try {
        await _restaurantShareService.attachPendingReferralToOrder(
          orderId: order.id,
          restaurantId: restaurantId,
          orderTotalAmount: totalAmount,
        );
      } catch (referralError) {
        debugPrint('Erro ao anexar referral ao pedido: $referralError');
      }

      if (useAtomicWalletCheckout && order.hasConfirmedPayment) {
        await _notifyImmediateRestaurantPaidOrder(order);
      }

      return order;
    } on PostgrestException catch (e) {
      debugPrint('Erro ao criar pedido (Postgrest): ${e.message}');
      final mapped = _mapCreateOrderErrorMessage(e.message);
      throw Exception(
        mapped.isNotEmpty ? mapped : 'order_creation_failed',
      );
    } catch (e) {
      debugPrint('Erro ao criar pedido: $e');
      throw Exception(e.toString().replaceFirst('Exception: ', ''));
    }
  }

  Future<List<Order>> getClientOrders() async {
    try {
      final user = _supabase.auth.currentUser;
      if (user == null) return [];

      await _triggerPreparationSweep();

      final primaryResponse = await _supabase
          .from('orders')
          .select(
            '*, restaurants(name,address,neighborhood,city,latitude,longitude,estimated_delivery_time), payment_splits(restaurant_confirmed_at,status)',
          )
          .eq('client_id', user.id)
          .order('created_at', ascending: false);

      final secondaryResponse = await _supabase
          .from('orders')
          .select(
            '*, restaurants(name,address,neighborhood,city,latitude,longitude,estimated_delivery_time), payment_splits(restaurant_confirmed_at,status)',
          )
          .eq('customer_id', user.id)
          .order('created_at', ascending: false);

      final merged = <String, Map<String, dynamic>>{};
      for (final row in (primaryResponse as List)) {
        final data = Map<String, dynamic>.from(row as Map);
        final id = data['id']?.toString();
        if (id != null && id.isNotEmpty) {
          merged[id] = data;
        }
      }
      for (final row in (secondaryResponse as List)) {
        final data = Map<String, dynamic>.from(row as Map);
        final id = data['id']?.toString();
        if (id != null && id.isNotEmpty) {
          merged[id] = data;
        }
      }

      for (final data in merged.values) {
        await _ensureOrderPreparationState(data);
        await _hydrateOrderCourierAssignment(data, persist: true);
      }

      final orders = merged.values.map(Order.fromMap).toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return orders;
    } catch (e) {
      debugPrint('Erro ao buscar pedidos: $e');
      return [];
    }
  }

  Future<Order?> getOrderById(String orderId) async {
    try {
      final user = _supabase.auth.currentUser;
      if (user == null) return null;

      await _triggerPreparationSweep();

      final ownedResponse = await _supabase
          .from('orders')
          .select(
            '*, restaurants(name,address,neighborhood,city,latitude,longitude,estimated_delivery_time), payment_splits(restaurant_confirmed_at,status)',
          )
          .eq('id', orderId)
          .or(
            'client_id.eq.${user.id},customer_id.eq.${user.id},courier_id.eq.${user.id}',
          )
          .maybeSingle();

      if (ownedResponse != null) {
        final ownedMap = Map<String, dynamic>.from(ownedResponse);
        await _ensureOrderPreparationState(ownedMap);
        await _hydrateOrderCourierAssignment(ownedMap, persist: true);
        return Order.fromMap(ownedMap);
      }

      final directResponse = await _supabase
          .from('orders')
          .select(
            '*, restaurants(name,address,neighborhood,city,latitude,longitude,estimated_delivery_time), payment_splits(restaurant_confirmed_at,status)',
          )
          .eq('id', orderId)
          .maybeSingle();

      if (directResponse != null) {
        final directMap = Map<String, dynamic>.from(directResponse);
        await _ensureOrderPreparationState(directMap);
        await _hydrateOrderCourierAssignment(directMap, persist: true);
        return Order.fromMap(directMap);
      }

      return null;
    } catch (e) {
      debugPrint('Erro ao buscar pedido: $e');
      return null;
    }
  }

  Future<Order?> waitForOrderVisibility(
    String orderId, {
    int attempts = 6,
    Duration delay = const Duration(milliseconds: 500),
  }) async {
    for (var index = 0; index < attempts; index++) {
      final order = await getOrderById(orderId);
      if (order != null) {
        return order;
      }
      if (index < attempts - 1) {
        await Future<void>.delayed(delay);
      }
    }
    return null;
  }

  Future<List<OrderItem>> getOrderItems(String orderId) async {
    try {
      final response = await _supabase
          .from('order_items')
          .select('*, menu_items(*)')
          .eq('order_id', orderId);

      return (response as List).map((data) {
        final menuItemData = data['menu_items'];
        MenuItem? menuItem;

        if (menuItemData != null) {
          menuItem = MenuItem(
            id: menuItemData['id'],
            restaurantId: menuItemData['restaurant_id'],
            name: menuItemData['name'] ?? 'Item',
            description: menuItemData['description'],
            price: (menuItemData['price'] as num?)?.toDouble() ?? 0.0,
            imageUrl: menuItemData['image_url'],
            category: menuItemData['category'],
            isAvailable: menuItemData['is_available'] ?? true,
            createdAt: menuItemData['created_at'] != null
                ? DateTime.parse(menuItemData['created_at'])
                : ServerClockService.instance.now(),
          );
        }

        return OrderItem(
          id: data['id'],
          orderId: data['order_id'],
          menuItemId: data['menu_item_id'],
          quantity: data['quantity'],
          unitPrice:
              ((data['unit_price'] ?? data['price']) as num?)?.toDouble() ??
              0.0,
          subtotal:
              (data['subtotal'] as num?)?.toDouble() ??
              ((((data['unit_price'] ?? data['price']) as num?)?.toDouble() ??
                      0.0) *
                  ((data['quantity'] as num?)?.toInt() ?? 0)),
          menuItem: menuItem,
        );
      }).toList();
    } catch (e) {
      debugPrint('Erro ao buscar itens do pedido: $e');
      return [];
    }
  }

  Future<bool> updateOrderStatus(String orderId, String status) async {
    try {
      Map<String, dynamic>? updated;
      final rpcResponse = await _supabase.rpc(
        'restaurant_update_order_status',
        params: {'p_order_id': orderId, 'p_status': status},
      );
      if (rpcResponse is Map) {
        updated = Map<String, dynamic>.from(rpcResponse);
      }
      final updatedStatus = updated?['status']?.toString();
      if (updated == null || updatedStatus != status) {
        debugPrint(
          'Erro ao atualizar status: pedido nï¿½o confirmou mudanï¿½a para $status',
        );
        return false;
      }
      String? deliveryType = updated['delivery_type']?.toString();
      final deliveryFee = (updated['delivery_fee'] as num?)?.toDouble() ?? 0.0;
      if (deliveryType == null || deliveryType.isEmpty) {
        deliveryType = deliveryFee > 0 ? 'delivery' : 'pickup';
      }
      if ((status == 'accepted' || status == 'ready') &&
          deliveryType != 'pickup' &&
          deliveryFee > 0) {
        await _deliveryService.notifyNearbyCouriers(orderId);
      }
      await _notifyStatusChangePush(
        orderId: orderId,
        status: status,
        updatedOrder: updated,
      );
      return true;
    } catch (e) {
      debugPrint('Erro ao atualizar status: $e');
      return false;
    }
  }

  Future<bool> cancelOrder(String orderId) async {
    try {
      final user = _supabase.auth.currentUser;
      if (user == null) {
        throw Exception('Usuï¿½rio nï¿½o autenticado');
      }

      final response = await _supabase.rpc(
        'process_order_cancellation',
        params: {
          'p_order_id': orderId,
          'p_user_id': user.id,
          'p_reason': 'customer_requested',
        },
      );

      if (response == null) return false;
      final data = Map<String, dynamic>.from(response as Map);
      return data['success'] == true;
    } catch (e) {
      debugPrint('Erro ao cancelar pedido: $e');
      return false;
    }
  }

  Future<Map<String, dynamic>?> previewCancellation(String orderId) async {
    try {
      final order = await getOrderById(orderId);
      if (order == null) return null;

      double refundPercent = 0;
      String message = '';
      bool allowed = true;

      switch (order.status) {
        case OrderStatus.pending:
        case OrderStatus.paymentAuthorized:
          refundPercent = 100;
          message =
              'Pode cancelar sem custo. O valor volta por inteiro para a carteira.';
          break;
        case OrderStatus.paid:
          refundPercent = 100;
          message =
              'O pagamento entrou, mas o restaurante ainda nao confirmou. O reembolso sera total.';
          break;
        case OrderStatus.accepted:
          refundPercent = 80;
          message =
              'O restaurante ja aceitou o pedido. Se cancelar agora, o reembolso sera de 80%.';
          break;
        case OrderStatus.preparing:
          refundPercent = 0;
          message =
              'O pedido ja esta em preparacao. Ainda pode cancelar, mas sem reembolso.';
          break;
        case OrderStatus.ready:
        case OrderStatus.awaitingPickupConfirmation:
        case OrderStatus.pickedUp:
        case OrderStatus.inDelivery:
        case OrderStatus.courierAssigned:
        case OrderStatus.inTransit:
        case OrderStatus.arrived:
        case OrderStatus.deliveryFailedOtp:
        case OrderStatus.onTheWay:
        case OrderStatus.delivered:
        case OrderStatus.disputed:
        case OrderStatus.autoCompleted:
        case OrderStatus.completed:
        case OrderStatus.refunded:
        case OrderStatus.expired:
        case OrderStatus.paymentFailed:
        case OrderStatus.cancelled:
          allowed = false;
          message =
              'Este pedido ja avancou demasiado no fluxo e ja nao pode ser cancelado no app.';
          break;
      }

      final refundAmount = double.parse(
        (order.totalAmount * (refundPercent / 100)).toStringAsFixed(2),
      );

      return {
        'allowed': allowed,
        'refund_percent': refundPercent,
        'refund_amount': refundAmount,
        'message': message,
        'status': order.status.value,
      };
    } catch (e) {
      debugPrint('Erro ao simular cancelamento: $e');
      return null;
    }
  }

  Future<bool> confirmDelivery(String orderId) async {
    final result = await confirmDeliveryDetailed(orderId);
    return result.success;
  }

  Future<DeliveryConfirmationResult> confirmDeliveryDetailed(
    String orderId,
  ) async {
    try {
      final orderRow = await _supabase
          .from('orders')
          .select(
            'delivery_type, delivery_fee, status, courier_id, created_at, updated_at, preparing_at, estimated_delivery_time',
          )
          .eq('id', orderId)
          .maybeSingle();
      if (orderRow == null) {
        return const DeliveryConfirmationResult(
          success: false,
          message:
              'Nao encontramos o pedido agora. Atualize e tente novamente.',
        );
      }
      final deliveryType = orderRow['delivery_type']?.toString();
      final deliveryFee = (orderRow['delivery_fee'] as num?)?.toDouble() ?? 0.0;
      var status = orderRow['status']?.toString();
      final courierId = orderRow['courier_id']?.toString();
      final isPickup = deliveryType == 'pickup' || deliveryFee <= 0;
      final readyNoCourier =
          status == 'ready' && (courierId == null || courierId.isEmpty);

      Future<String?> fetchLatestStatus() async {
        try {
          final latest = await _supabase
              .from('orders')
              .select('status')
              .eq('id', orderId)
              .maybeSingle();
          return latest?['status']?.toString();
        } catch (_) {
          return null;
        }
      }

      DeliveryConfirmationResult successResult(String? currentStatus) =>
          DeliveryConfirmationResult(
            success: true,
            status: currentStatus,
            message: isPickup
                ? 'Retirada confirmada. Pedido concluido.'
                : 'Entrega confirmada. Pedido concluido.',
          );

      DeliveryConfirmationResult failureResult({
        required String message,
        String? currentStatus,
      }) => DeliveryConfirmationResult(
        success: false,
        message: message,
        status: currentStatus,
      );

      bool isSettledStatus(String? value) =>
          value == 'completed' || value == 'auto_completed';

      Future<void> notifyIfCustomerConfirmed(String? value) async {
        if (value == 'completed') {
          await _notifyParticipantsForDeliveryConfirmed(orderId);
        }
      }

      if (isSettledStatus(status)) {
        return successResult(status);
      }

      if (status == 'disputed') {
        return failureResult(
          message:
              'Existe um problema reportado nesta entrega. O suporte vai analisar antes de concluir o pedido.',
          currentStatus: status,
        );
      }

      if (status == 'delivery_failed_otp') {
        return failureResult(
          message:
              'O OTP falhou nesta entrega e a equipa admin foi alertada para rever o caso com seguranca.',
          currentStatus: status,
        );
      }

      Map<String, dynamic>? mapFromRpc(dynamic value) {
        if (value is Map) {
          return Map<String, dynamic>.from(value);
        }
        if (value is List && value.isNotEmpty && value.first is Map) {
          return Map<String, dynamic>.from(value.first as Map);
        }
        return null;
      }

      DeliveryConfirmationResult? parseFunctionFailure(
        Map<String, dynamic> data, {
        String? currentStatus,
      }) {
        final code = data['code']?.toString();
        final errorMessage = data['error']?.toString().trim();
        if (errorMessage == null || errorMessage.isEmpty) {
          return null;
        }

        final mappedMessage = code == 'invalid_order_status'
            ? 'O pedido ainda nao esta pronto para retirada.'
            : code == 'not_order_owner'
            ? 'Pedido nao autorizado para esta conta.'
            : code == 'order_not_pickup'
            ? 'Este pedido nao e de retirada.'
            : code == 'user_not_authenticated'
            ? 'Sessao invalida. Entre novamente e tente outra vez.'
            : errorMessage;

        return failureResult(
          message: mappedMessage,
          currentStatus: currentStatus,
        );
      }

      Future<DeliveryConfirmationResult?> tryConfirmPickupViaFunction() async {
        try {
          Map<String, dynamic>? data;
          try {
            final response = await _supabase.functions.invoke(
              'confirm-delivery',
              headers: await _authHeaders(),
              body: {'order_id': orderId},
            );
            final payload = response.data;
            if (payload is Map) {
              data = Map<String, dynamic>.from(payload);
            }
          } catch (sdkError) {
            debugPrint(
              'Erro ao chamar Edge Function confirm-delivery via SDK para pickup $orderId: $sdkError',
            );
          }

          data ??= await _invokeFunctionDirect(
            'confirm-delivery',
            body: {'order_id': orderId},
          );
          if (data == null) {
            return null;
          }

          if (data['success'] == true) {
            final responseData = data['data'] is Map
                ? Map<String, dynamic>.from(data['data'] as Map)
                : const <String, dynamic>{};
            final confirmedStatus =
                responseData['status']?.toString() ?? await fetchLatestStatus();
            if (isSettledStatus(confirmedStatus)) {
              await notifyIfCustomerConfirmed(confirmedStatus);
              return successResult(confirmedStatus);
            }
          }

          debugPrint(
            'Confirm delivery fallback para pickup falhou em $orderId: ${data['error']}',
          );
          return parseFunctionFailure(
            data,
            currentStatus: await fetchLatestStatus(),
          );
        } catch (error) {
          debugPrint(
            'Erro ao chamar Edge Function confirm-delivery para pickup $orderId: $error',
          );
          return null;
        }
      }

      if (isPickup || readyNoCourier) {
        final pickupAwaitingCustomer =
            status == 'ready' || status == 'awaiting_pickup_confirmation';
        if (!pickupAwaitingCustomer && !isSettledStatus(status)) {
          return failureResult(
            message: 'O pedido ainda nao esta pronto para retirada.',
            currentStatus: status,
          );
        }
        final currentUserId = _supabase.auth.currentUser?.id;
        dynamic rpcResponse;
        try {
          rpcResponse = await _supabase.rpc(
            'client_confirm_pickup_v2',
            params: {'p_order_id': orderId, 'p_customer_id': currentUserId},
          );
        } on PostgrestException catch (error) {
          debugPrint(
            'Erro ao chamar client_confirm_pickup_v2 para $orderId: ${error.message}',
          );
          final functionResult = await tryConfirmPickupViaFunction();
          if (functionResult != null) return functionResult;
          try {
            rpcResponse = await _supabase.rpc(
              'client_confirm_pickup',
              params: {'p_order_id': orderId},
            );
          } catch (legacyError) {
            debugPrint(
              'Erro ao chamar client_confirm_pickup legado para $orderId: $legacyError',
            );
          }
        }
        final updated = mapFromRpc(rpcResponse);
        final updatedStatus = updated?['status']?.toString();
        if (updated != null && isSettledStatus(updatedStatus)) {
          await notifyIfCustomerConfirmed(updatedStatus);
          return successResult(updatedStatus);
        }
        final functionResult = await tryConfirmPickupViaFunction();
        if (functionResult != null) return functionResult;
        final latestStatus = await fetchLatestStatus();
        if (isSettledStatus(latestStatus)) {
          await notifyIfCustomerConfirmed(latestStatus);
          return successResult(latestStatus);
        }
        return failureResult(
          message:
              'Ainda nao conseguimos confirmar a retirada. Tente novamente em instantes.',
          currentStatus: latestStatus ?? status,
        );
      }

      if (status != 'delivered' && !isSettledStatus(status)) {
        return failureResult(
          message: status == 'arrived' || status == 'in_transit'
              ? 'O estafeta ainda precisa validar o codigo de entrega antes da tua confirmacao final.'
              : status == 'delivery_failed_otp'
              ? 'O OTP falhou nesta entrega e a equipa admin esta a rever o caso.'
              : status == 'ready'
              ? 'O pedido ainda esta a ser levantado pelo estafeta.'
              : 'A entrega ainda nao chegou ao ponto de confirmacao final.',
          currentStatus: status,
        );
      }

      Map<String, dynamic>? data;
      try {
        final response = await _supabase.functions
            .invoke(
              'confirm-delivery',
              headers: await _authHeaders(),
              body: {'order_id': orderId},
            )
            .timeout(const Duration(seconds: 12));
        final payload = response.data;
        if (payload is Map) {
          data = Map<String, dynamic>.from(payload);
        }
      } catch (sdkError) {
        debugPrint(
          'Erro ao chamar Edge Function confirm-delivery via SDK para entrega $orderId: $sdkError',
        );
      }

      data ??= await _invokeFunctionDirect(
        'confirm-delivery',
        body: {'order_id': orderId},
      );

      if (data == null) {
        debugPrint('Erro ao confirmar entrega: resposta nula');
        final latestStatus = await fetchLatestStatus();
        if (isSettledStatus(latestStatus)) {
          await notifyIfCustomerConfirmed(latestStatus);
          return successResult(latestStatus);
        }
        return failureResult(
          message: latestStatus == 'delivered'
              ? 'A entrega foi marcada, mas a confirmacao final ainda esta a fechar. Tente novamente em instantes.'
              : 'Ainda nao conseguimos confirmar a entrega. Tente novamente em instantes.',
          currentStatus: latestStatus ?? status,
        );
      }

      if (data['success'] == true) {
        final responseData = data['data'] is Map
            ? Map<String, dynamic>.from(data['data'] as Map)
            : const <String, dynamic>{};
        final confirmedStatus =
            responseData['status']?.toString() ?? await fetchLatestStatus();
        if (responseData['status'] == null &&
            kDebugMode &&
            responseData.isNotEmpty) {
          debugPrint(
            'Confirm delivery respondeu sem status explicito para $orderId.',
          );
        }
        if (isSettledStatus(confirmedStatus)) {
          await notifyIfCustomerConfirmed(confirmedStatus);
          return successResult(confirmedStatus);
        }
        return failureResult(
          message: confirmedStatus == 'delivered'
              ? 'A entrega foi marcada, mas ainda nao ficou concluida. Tente novamente em instantes.'
              : 'Ainda nao conseguimos concluir a entrega. Aguarde um instante e tente novamente.',
          currentStatus: confirmedStatus ?? status,
        );
      }

      debugPrint('Erro da Edge Function: ${data['error']}');
      if (readyNoCourier) {
        final fallback = await _supabase.rpc(
          'client_confirm_pickup',
          params: {'p_order_id': orderId},
        );
        final updated = mapFromRpc(fallback);
        final updatedStatus = updated?['status']?.toString();
        if (updated != null && isSettledStatus(updatedStatus)) {
          await notifyIfCustomerConfirmed(updatedStatus);
          return successResult(updatedStatus);
        }
      }
      final latestStatus = await fetchLatestStatus();
      if (isSettledStatus(latestStatus)) {
        await notifyIfCustomerConfirmed(latestStatus);
        return successResult(latestStatus);
      }
      return failureResult(
        message: latestStatus == 'disputed'
            ? 'Foi reportado um problema nesta entrega. A equipa vai analisar antes de concluir o pedido.'
            : latestStatus == 'delivery_failed_otp'
            ? 'O OTP falhou nesta entrega e a equipa admin esta a rever o caso.'
            : latestStatus == 'delivered'
            ? 'A entrega foi marcada e ainda esta a fechar a confirmacao final. Tente novamente em instantes.'
            : 'Ainda nao foi possivel concluir a entrega. Aguarde um instante e tente novamente.',
        currentStatus: latestStatus ?? status,
      );
    } catch (e) {
      debugPrint('Erro ao confirmar entrega: $e');
      try {
        final latest = await _supabase
            .from('orders')
            .select('status')
            .eq('id', orderId)
            .maybeSingle();
        final latestStatus = latest?['status']?.toString();
        if (latestStatus == 'completed' || latestStatus == 'auto_completed') {
          return DeliveryConfirmationResult(
            success: true,
            message: 'Recebimento confirmado com sucesso.',
            status: latestStatus,
          );
        }
        if (latestStatus == 'disputed') {
          return const DeliveryConfirmationResult(
            success: false,
            message:
                'Foi reportado um problema nesta entrega. A equipa vai analisar antes de concluir o pedido.',
            status: 'disputed',
          );
        }
        if (latestStatus == 'delivery_failed_otp') {
          return const DeliveryConfirmationResult(
            success: false,
            message:
                'O OTP falhou nesta entrega e a equipa admin esta a rever o caso.',
            status: 'delivery_failed_otp',
          );
        }
        if (latestStatus == 'delivered') {
          return const DeliveryConfirmationResult(
            success: false,
            message:
                'A entrega foi marcada, mas a confirmacao final ainda esta a fechar. Tente novamente em instantes.',
            status: 'delivered',
          );
        }
      } catch (_) {}
      return const DeliveryConfirmationResult(
        success: false,
        message:
            'Ainda nao foi possivel confirmar o recebimento. Tente novamente em instantes.',
      );
    }
  }

  Future<void> _notifyParticipantsForDeliveryConfirmed(String orderId) async {
    try {
      final orderRow = await _supabase
          .from('orders')
          .select('id, client_id, customer_id, courier_id, restaurant_id')
          .eq('id', orderId)
          .maybeSingle();
      if (orderRow == null) return;

      final clientId = (orderRow['client_id'] ?? orderRow['customer_id'])
          ?.toString();
      var courierId = orderRow['courier_id']?.toString();
      final restaurantId = orderRow['restaurant_id']?.toString();
      final orderRef = _orderRef(orderId);

      if (courierId == null || courierId.trim().isEmpty) {
        try {
          final delivery = await _supabase
              .from('deliveries')
              .select('courier_id')
              .eq('order_id', orderId)
              .order('updated_at', ascending: false)
              .limit(1)
              .maybeSingle();
          final fallbackCourierId =
              delivery?['courier_id']?.toString().trim() ?? '';
          if (fallbackCourierId.isNotEmpty) {
            courierId = fallbackCourierId;
            await _supabase
                .from('orders')
                .update({
                  'courier_id': fallbackCourierId,
                  'updated_at': ServerClockService.instance.nowIso8601Utc(),
                })
                .eq('id', orderId);
          }
        } catch (e) {
          debugPrint(
            'Erro ao recuperar courier_id para notificacoes do pedido $orderId: $e',
          );
        }
      }

      String senderName = 'Cliente';
      if (clientId != null && clientId.isNotEmpty) {
        final clientProfile = await _supabase
            .from('profiles')
            .select('full_name')
            .eq('id', clientId)
            .maybeSingle();
        senderName =
            clientProfile?['full_name']?.toString().trim().isNotEmpty == true
            ? clientProfile!['full_name'].toString().trim()
            : senderName;
      }

      try {
        await _supabase.from('messages').insert({
          'order_id': orderId,
          'sender_id': clientId,
          'sender_name': senderName,
          'sender_role': 'client',
          'text':
              'Recebi o pedido $orderRef. Obrigado! Voltem sempre a contar comigo.',
        });
      } catch (e) {
        debugPrint('Erro ao registrar mensagem de entrega concluÃ­da: $e');
      }

      if (restaurantId != null && restaurantId.isNotEmpty) {
        final restaurant = await _supabase
            .from('restaurants')
            .select('owner_id, name')
            .eq('id', restaurantId)
            .maybeSingle();
        final ownerId = restaurant?['owner_id']?.toString();
        if (ownerId != null && ownerId.isNotEmpty) {
          await _notificationDispatch.sendToUser(
            userId: ownerId,
            type: 'ORDER_DELIVERED',
            title: 'Pedido $orderRef concluÃ­do âœ…',
            body:
                '$senderName confirmou o recebimento do pedido $orderRef. Volte sempre!',
            action: 'OPEN_CHAT',
            entityId: orderId,
            priority: 'HIGH',
            channel: 'restaurant',
            data: {'order_id': orderId, 'order_ref': orderRef},
            metadata: {'order_id': orderId, 'order_ref': orderRef},
          );
        }
      }

      if (courierId != null && courierId.isNotEmpty) {
        await _notificationDispatch.sendToUser(
          userId: courierId,
          type: 'ORDER_DELIVERED',
          title: 'Entrega $orderRef concluÃ­da âœ…',
          body:
              '$senderName confirmou o recebimento do pedido $orderRef. Obrigado pela entrega.',
          action: 'OPEN_CHAT',
          entityId: orderId,
          priority: 'HIGH',
          channel: 'delivery',
          data: {'order_id': orderId, 'order_ref': orderRef},
          metadata: {'order_id': orderId, 'order_ref': orderRef},
        );
      }
    } catch (e) {
      debugPrint('Erro ao notificar participantes apÃ³s entrega: $e');
    }
  }

  Future<Order?> getActiveOrder() async {
    try {
      final user = _supabase.auth.currentUser;
      if (user == null) return null;

      await _triggerPreparationSweep();

      final activeStatuses = [
        'pending',
        'payment_authorized',
        'paid',
        'accepted',
        'preparing',
        'ready',
        'in_transit',
        'courier_assigned',
        'on_the_way',
        'arrived',
        'delivery_failed_otp',
        'delivered',
        'disputed',
      ];

      final primaryResponse = await _supabase
          .from('orders')
          .select(
            '*, restaurants(name,address,neighborhood,city,latitude,longitude,estimated_delivery_time), payment_splits(restaurant_confirmed_at,status)',
          )
          .eq('client_id', user.id)
          .order('created_at', ascending: false)
          .limit(20);

      final secondaryResponse = await _supabase
          .from('orders')
          .select(
            '*, restaurants(name,address,neighborhood,city,latitude,longitude,estimated_delivery_time), payment_splits(restaurant_confirmed_at,status)',
          )
          .eq('customer_id', user.id)
          .order('created_at', ascending: false)
          .limit(20);

      final merged = <String, Map<String, dynamic>>{};
      for (final row in (primaryResponse as List)) {
        final data = Map<String, dynamic>.from(row as Map);
        final id = data['id']?.toString();
        if (id != null && id.isNotEmpty) {
          merged[id] = data;
        }
      }
      for (final row in (secondaryResponse as List)) {
        final data = Map<String, dynamic>.from(row as Map);
        final id = data['id']?.toString();
        if (id != null && id.isNotEmpty) {
          merged[id] = data;
        }
      }

      final activeRows = merged.values
          .where((data) => activeStatuses.contains(data['status']))
          .toList();

      for (final row in activeRows) {
        await _ensureOrderPreparationState(row);
        await _hydrateOrderCourierAssignment(row, persist: true);
      }

      final activeOrders = activeRows.map(Order.fromMap).toList();

      if (activeOrders.isEmpty) return null;
      activeOrders.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return activeOrders.first;
    } catch (e) {
      debugPrint('Erro ao buscar pedido ativo: $e');
      return null;
    }
  }

  Future<List<Map<String, dynamic>>> getOrderEvents(String orderId) async {
    try {
      final response = await _supabase
          .from('order_events')
          .select()
          .eq('order_id', orderId)
          .order('created_at', ascending: false)
          .limit(30);
      return List<Map<String, dynamic>>.from(response);
    } catch (e) {
      debugPrint('Erro ao buscar eventos do pedido: $e');
      return [];
    }
  }

  Future<bool> openOrderDispute({
    required String orderId,
    required String disputeType,
    required String reason,
    required String openedByRole,
    Map<String, dynamic>? metadata,
  }) async {
    try {
      final user = _supabase.auth.currentUser;
      if (user == null) {
        throw Exception('Usuï¿½rio nï¿½o autenticado');
      }

      final response = await _supabase.rpc(
        'open_order_dispute',
        params: {
          'p_order_id': orderId,
          'p_opened_by': user.id,
          'p_opened_by_role': openedByRole,
          'p_dispute_type': disputeType,
          'p_reason': reason,
          'p_metadata': metadata ?? <String, dynamic>{},
        },
      );

      if (response == null) return false;
      final data = Map<String, dynamic>.from(response as Map);
      return data['success'] == true;
    } catch (e) {
      debugPrint('Erro ao abrir disputa: $e');
      return false;
    }
  }

  Future<String?> getDeliveryOtpCode(String orderId) async {
    try {
      final response = await _supabase
          .from('delivery_otp_secrets')
          .select('otp_code')
          .eq('order_id', orderId)
          .maybeSingle();
      return response?['otp_code']?.toString();
    } catch (e) {
      debugPrint('Erro ao buscar codigo OTP da entrega: $e');
      return null;
    }
  }

  Future<OrderActionResult> regenerateDeliveryOtp(String orderId) async {
    try {
      final response = await _supabase.rpc(
        'request_delivery_otp_regeneration',
        params: {'p_order_id': orderId},
      );
      if (response == null || response is! Map) {
        return const OrderActionResult(
          success: false,
          message: 'Nao foi possivel gerar um novo codigo agora.',
        );
      }

      final data = Map<String, dynamic>.from(response);
      final success = data['success'] == true;
      var message = success
          ? 'Novo codigo gerado com sucesso.'
          : (data['error']?.toString() ??
                'Nao foi possivel gerar um novo codigo agora.');

      if (success) {
        final smsResult = await _deliveryService.sendDeliveryOtpSms(
          orderId: orderId,
          force: true,
          reason: 'regenerated',
        );
        if (smsResult.success) {
          message = smsResult.duplicate
              ? 'Novo codigo gerado com sucesso.'
              : 'Novo codigo gerado e enviado por SMS.';
        } else {
          message =
              'Novo codigo gerado com sucesso. O SMS nao foi reenviado, mas o codigo ja esta visivel no app.';
        }
      }

      return OrderActionResult(
        success: success,
        message: message,
        status: data['status']?.toString(),
        data: data,
      );
    } catch (e) {
      debugPrint('Erro ao regenerar OTP de entrega: $e');
      return const OrderActionResult(
        success: false,
        message: 'Nao foi possivel gerar um novo codigo agora.',
      );
    }
  }

  Future<OrderActionResult> requestDeliveryExtension(
    String orderId, {
    int extraMinutes = 10,
  }) async {
    try {
      final response = await _supabase.rpc(
        'client_request_delivery_extension',
        params: {'p_order_id': orderId, 'p_extra_minutes': extraMinutes},
      );
      if (response == null || response is! Map) {
        return const OrderActionResult(
          success: false,
          message: 'Nao foi possivel pedir mais tempo agora.',
        );
      }

      final data = Map<String, dynamic>.from(response);
      final success = data['success'] == true;
      return OrderActionResult(
        success: success,
        message: success
            ? 'Mais tempo concedido. A entrega nao sera fechada durante a extensao.'
            : (data['error']?.toString() ??
                  'Nao foi possivel pedir mais tempo agora.'),
        status: data['status']?.toString(),
        data: data,
      );
    } catch (e) {
      debugPrint('Erro ao pedir mais tempo para entrega: $e');
      return const OrderActionResult(
        success: false,
        message: 'Nao foi possivel pedir mais tempo agora.',
      );
    }
  }

  Future<OrderActionResult> reportDeliveryProblem({
    required String orderId,
    required String reason,
    String disputeType = 'delivery_issue',
  }) async {
    try {
      final response = await _supabase.rpc(
        'client_report_delivery_problem',
        params: {
          'p_order_id': orderId,
          'p_reason': reason,
          'p_dispute_type': disputeType,
        },
      );
      if (response == null || response is! Map) {
        return const OrderActionResult(
          success: false,
          message: 'Nao foi possivel reportar o problema agora.',
        );
      }

      final data = Map<String, dynamic>.from(response);
      final success = data['success'] == true;
      return OrderActionResult(
        success: success,
        message: success
            ? 'Problema reportado. O pedido entrou em analise e o auto-fecho foi bloqueado.'
            : (data['error']?.toString() ??
                  'Nao foi possivel reportar o problema agora.'),
        status: data['status']?.toString(),
        data: data,
      );
    } catch (e) {
      debugPrint('Erro ao reportar problema da entrega: $e');
      return const OrderActionResult(
        success: false,
        message: 'Nao foi possivel reportar o problema agora.',
      );
    }
  }

  Future<OrderActionResult> markDeliveryOtpFailed({
    required String orderId,
    String reason = 'otp_failed',
    String? notes,
  }) async {
    try {
      final response = await _supabase.rpc(
        'courier_mark_delivery_otp_failed',
        params: {'p_order_id': orderId, 'p_reason': reason, 'p_notes': notes},
      );
      if (response == null || response is! Map) {
        return const OrderActionResult(
          success: false,
          message:
              'Nao foi possivel enviar este caso para revisao admin agora.',
        );
      }

      final data = Map<String, dynamic>.from(response);
      final success = data['success'] == true;
      return OrderActionResult(
        success: success,
        message: success
            ? 'Caso enviado para revisao admin. A entrega fica bloqueada ate decisao segura.'
            : (data['error']?.toString() ??
                  'Nao foi possivel enviar este caso para revisao admin agora.'),
        status: data['status']?.toString(),
        data: data,
      );
    } catch (e) {
      debugPrint('Erro ao marcar falha de OTP da entrega: $e');
      return const OrderActionResult(
        success: false,
        message: 'Nao foi possivel enviar este caso para revisao admin agora.',
      );
    }
  }

  Future<OrderActionResult> adminResolveDeliveryOtpFailure({
    required String orderId,
    required String reason,
    required String proofType,
    String? notes,
    String? proofUrl,
    double? gpsLatitude,
    double? gpsLongitude,
    bool callAttempted = false,
    bool markAsDisputed = false,
  }) async {
    try {
      final response = await _supabase.rpc(
        'admin_override_delivery_after_failed_otp',
        params: {
          'p_order_id': orderId,
          'p_reason': reason,
          'p_notes': notes,
          'p_proof_type': proofType,
          'p_proof_url': proofUrl,
          'p_gps_latitude': gpsLatitude,
          'p_gps_longitude': gpsLongitude,
          'p_call_attempted': callAttempted,
          'p_mark_as_disputed': markAsDisputed,
        },
      );
      if (response == null || response is! Map) {
        return const OrderActionResult(
          success: false,
          message: 'Nao foi possivel concluir a revisao admin agora.',
        );
      }

      final data = Map<String, dynamic>.from(response);
      final success = data['success'] == true;
      return OrderActionResult(
        success: success,
        message: success
            ? (markAsDisputed
                  ? 'Caso enviado para disputa com trilha auditada.'
                  : 'Entrega concluida manualmente com trilha auditada.')
            : (data['error']?.toString() ??
                  'Nao foi possivel concluir a revisao admin agora.'),
        status: data['status']?.toString(),
        data: data,
      );
    } catch (e) {
      debugPrint('Erro ao resolver falha de OTP no admin: $e');
      return const OrderActionResult(
        success: false,
        message: 'Nao foi possivel concluir a revisao admin agora.',
      );
    }
  }
}
