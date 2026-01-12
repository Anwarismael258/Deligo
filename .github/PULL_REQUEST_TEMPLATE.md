## Resumo
(Descreve o que este PR adiciona — ex.: workflows + mapping para compliance de Edge Functions)

## Check pré-merge obrigatórios
- [ ] .github/compliance-owner-map.json atualizado com todos os owners relevantes
- [ ] Secrets definidos no repo: PGHOST, PGPORT, PGDATABASE, PGUSER, PGPASSWORD
- [ ] Executado localmente: ./validate_owner_mapping.sh (ou rodado a query SQL abaixo)
  - SQL quick-check:
    ```sql
    select distinct owner
    from app.edge_functions_registry
    where uses_service_role = true
      and audit_last_review is null
    order by owner;
    ```
  - Confirmar que nenhum owner listado falta no mapping JSON

## Como testar (dry-run)
1. Commit + push do PR.
2. Actions → escolher "Edge Functions – Service Role Compliance" → Run workflow (workflow_dispatch).
3. Verificar artifacts na execução: edge_functions_violators.csv / .json
4. Se houver violadores, verificar a execução do workflow de issues e confirmar assignees conforme mapping.

## Notas
- A Action de criação de issues falhará se existir owner não mapeado — isso é intencional.
- Se precisares de ajuda para executar a validação local, contactar @platform-team.
