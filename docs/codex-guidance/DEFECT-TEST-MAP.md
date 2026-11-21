# Карта «дефект → защищающий тест»

Заготовка, сгенерированная из `reports/DEFECTS.md` на ревизии `850ce47`. Столбцы «Тест» и «Модуль» пусты намеренно: их заполняет Codex в задании T0 **по коду и тестам**, а не по памяти. Строка, для которой тест не найден, получает статус `NO_TEST`, и это нужно показать владельцу, а не скрыть.

| Дефект | Приоритет | Заголовок | Защищающий тест (файл::имя) | Модуль после разбиения | Статус |
| --- | --- | --- | --- | --- | --- |
| RP-001 | P0 | unverified update confirmed | | | TODO |
| RP-002 | P1 | routing override success assumed without readback | | | TODO |
| RP-003 | P1 | rollback durability/completeness (inspection, not yet reproduced) | | | TODO |
| RP-004 | P1 | reinstall destroys client inventory (inspection) | | | TODO |
| RP-005 | P2 | intermittent DoH probe failure | | | TODO |
| RP-006 | P1 | auto failover exceeds the 60-second objective | | | TODO |
| RP-007 | P1 | removal deletes unrelated services | | | TODO |
| RP-008 |  | additional real ENOSPC coverage | | | TODO |
| RP-008 | P1 | preparation crash can leave supervision disabled | | | TODO |
| RP-009 | P1 | reinstall resets network policy and Hysteria certificate pin | | | TODO |
| RP-010 | P1 | HTTP/3 through stream-up times out | | | TODO |
| RP-011 | P1 | menu mutations bypass the CLI operation lock | | | TODO |
| RP-012 |  | live WireGuard MTU was not applied | | | TODO |
| RP-012 | P1 | inner WireGuard MTU prevents QUIC over both Hysteria transports | | | TODO |
| RP-013 | P1 | DNS reply source reused across resolver destinations | | | TODO |
| RP-014 | P1 | DoH diagnostic accepts invalid responses and returns false success | | | TODO |
| RP-015 | P1 | unmarked kernel TCP resets escape through VPS-1 underlay | | | TODO |
| RP-016 | P2 | code update unnecessarily depends on OS package mirrors | | | TODO |
| RP-017 | P1 | diagnostic errors still return success | | | TODO |
| RP-018 | P2 | egress diagnostics inspect the wrong firewalld setting | | | TODO |
| RP-019 | P1 | failed installer writes continue to READY | | | TODO |
| RP-020 | P2 | excluded inner-WG secrets and legacy TCP config remain on VPS-2 | | | TODO |
| RP-021 | P1 | restart commands hide service errors and omit inactive services | | | TODO |
