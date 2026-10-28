# Harvester: alertas por email com o Alertmanager embutido

[English](README.md) | **Português (pt-BR)**

> [!NOTE]
> Os alertas predefinidos **já estão habilitados e disparando** em uma instalação padrão do Harvester. Só falta o
> destino: de fábrica o Alertmanager envia tudo para um receiver `null`, que descarta. Basta apontá-lo para algum lugar.

> [!TIP]
> Caminho mais rápido: cole o bloco do [Início rápido](#1-início-rápido) em **Advanced -> Addons -> rancher-monitoring -> Edit YAML**,
> ou execute o [`harvester-alert-email.sh`](harvester-alert-email.sh) (use `--dry-run` primeiro).

> [!WARNING]
> **Espere uma rajada de emails na primeira aplicação.** Cada alerta que casar com a rota e estiver disparando naquele
> momento é enviado uma vez, e um email de "resolvido" chega quando ele normaliza. Veja antes o que está disparando
> ([seção 9](#9-visualizando-alertas-e-verificando-a-entrega)).

> [!WARNING]
> A senha SMTP fica armazenada **em texto puro** nos values do add-on (Opção A) ou em um Secret (Opção B).

> [!CAUTION]
> Um `AlertmanagerConfig` com namespace (Opção B) **não captura alertas de PVC e de Longhorn**; eles caem em `null` sem aviso.
> Prefira a Opção A para alertas de capacidade ([seção 7](#7-opção-b-um-alertmanagerconfig-com-namespace)).

Como fazer uma instalação **padrão** do Harvester 1.8.x enviar seus alertas predefinidos (armazenamento, disco,
capacidade de CPU/memória, saúde dos nós, ...) para um email, ou para um webhook/Slack, usando apenas o que acompanha o
add-on `rancher-monitoring`.

> Os comentários dos arquivos em `examples/` são bilíngues (inglês e pt-BR). Os prompts do script estão em inglês.

## O que há neste diretório

```
harvester-alert-email/
├── README.md                     guia em inglês
├── README.pt-BR.md               este guia
├── harvester-alert-email.sh      script interativo que aplica a configuração
├── docs/images/                  capturas de tela usadas nos guias
└── examples/
    ├── addon-values/             configuração do Alertmanager para colar no add-on (Opção A)
    │   ├── 01-email-everything.yaml
    │   ├── 02-email-capacity-only.yaml
    │   ├── 03-email-critical-only.yaml
    │   ├── 04-multiple-recipients.yaml
    │   ├── 05-open-relay-no-auth.yaml
    │   ├── 06-split-by-severity.yaml
    │   ├── 07-webhook-instead-of-email.yaml
    │   └── 08-slack.yaml
    ├── alertmanagerconfig/       objetos com namespace (Opção B)
    │   ├── 01-smtp-secret.yaml
    │   ├── 02-node-alerts-email.yaml
    │   └── 03-matcher-strategy-none.yaml
    └── prometheus-rules/
        ├── longhorn-capacity.yaml   alertas personalizados de uso de disco do Longhorn
        └── test-alert.yaml          alerta temporário sempre ativo para testes ponta a ponta
```

## Conteúdo

1. [Início rápido](#1-início-rápido)
2. [Como as peças se encaixam](#2-como-as-peças-se-encaixam)
3. [Estado padrão e alertas embutidos](#3-estado-padrão-e-alertas-embutidos)
4. [Antes de começar](#4-antes-de-começar)
5. [Receitas (Opção A, values do add-on)](#5-receitas-opção-a-values-do-add-on)
6. [Usando o script](#6-usando-o-script)
7. [Opção B: um AlertmanagerConfig com namespace](#7-opção-b-um-alertmanagerconfig-com-namespace)
8. [Alertas de capacidade do Longhorn](#8-alertas-de-capacidade-do-longhorn)
9. [Visualizando alertas e verificando a entrega](#9-visualizando-alertas-e-verificando-a-entrega)
10. [Solução de problemas](#10-solução-de-problemas)
11. [Reversão](#11-reversão)
12. [O que foi testado](#12-o-que-foi-testado)

---

## 1. Início rápido

Os alertas predefinidos **já estão habilitados e disparando**. Só falta o destino: por padrão o Alertmanager envia tudo
para um receiver `null`, que descarta.

Para enviar por email todos os alertas predefinidos (exceto o `Watchdog`, um heartbeat que dispara sempre):

1. Na UI do Harvester abra **Advanced -> Addons -> `rancher-monitoring` -> Edit YAML**.
2. Encontre o bloco `alertmanager:` existente. Substitua **somente a seção `config:`** (por padrão apenas
   `global: resolve_timeout: 5m`) pelo bloco abaixo. Deixe intactas todas as outras chaves
   (`enabled`, `service`, `alertmanagerSpec`, ...) e não crie uma segunda chave `alertmanager:`.
3. Ajuste o host SMTP, o remetente, as credenciais e o destinatário, e salve.
4. Aguarde 1-2 minutos enquanto o add-on é reimplantado (Advanced -> Addons volta a *Deploy Successful*).

```yaml
# Email EVERY predefined alert (except Watchdog/InfoInhibitor) to one address.
# Paste into: Advanced -> Addons -> rancher-monitoring -> Edit YAML.
# Replace only the `config:` section inside the existing `alertmanager:` block.
# [pt-BR] Envia por email TODOS os alertas predefinidos (exceto Watchdog/InfoInhibitor) para um endereço.
# Cole em: Advanced -> Addons -> rancher-monitoring -> Edit YAML.
# Substitua somente a seção `config:` dentro do bloco `alertmanager:` existente.
alertmanager:
  config:
    global:
      resolve_timeout: 5m
      smtp_smarthost: "smtp.customer.com:587"
      smtp_from: "harvester-alerts@customer.com"
      smtp_auth_username: "harvester-alerts@customer.com"
      smtp_auth_password: 'PASSWORD'
      smtp_require_tls: true
    route:
      receiver: "null"
      group_by: [alertname, namespace]
      routes:
        - receiver: "null"
          matchers: ['alertname=~"Watchdog|InfoInhibitor"']
        - receiver: email-ops
          repeat_interval: 4h
          matchers: ['alertname=~".+"']
    receivers:
      - name: "null"
      - name: email-ops
        email_configs:
          - to: "ops@customer.com"
            send_resolved: true
```

O que alterar:

| Campo | Significado |
|---|---|
| `smtp_smarthost` | Seu relay como `host:porta` (normalmente 587 com STARTTLS, ou 25 para um relay interno) |
| `smtp_from` | Endereço do remetente; o relay precisa aceitá-lo |
| `smtp_auth_username` / `smtp_auth_password` | Login do relay. Apague as duas linhas para um relay sem login. Um `'` literal na senha escreve-se `''` |
| `smtp_require_tls` | `true` para STARTTLS, `false` para um relay sem TLS |
| `to` | Destinatário. Repita a entrada `- to:` para mais destinatários |

Antes de salvar:

- A senha SMTP fica armazenada **em texto puro** nos values do add-on.
- **Espere uma rajada.** Cada alerta que casar e estiver disparando naquele momento é enviado uma vez, e um email de
  "resolvido" chega quando cada um normaliza. Veja antes o que está disparando (seção 9) e prefira uma receita mais
  restrita (seção 5) em clusters movimentados.

Prefere responder perguntas a editar YAML? Use o script (seção 6).

## 2. Como as peças se encaixam

```
PrometheusRule  ->  Prometheus   ->  Alertmanager  ->  email / webhook / Slack
(define alertas)    (avalia)         (roteia, envia)
```

| Objeto | Função | Onde alterar |
|---|---|---|
| PrometheusRule | Define um alerta ("disco > 80%") | Somente pelo Kubectl Shell (YAML) |
| Configuração do Alertmanager | SMTP, quais alertas vão para qual receiver | **Values do add-on** (Opção A) ou um objeto AlertmanagerConfig (Opção B) |

Só a segunda linha precisa mudar para começar a receber os alertas predefinidos. A UI do Harvester não tem uma página
de alertas própria, mas o Grafana para o qual ela aponta tem (seção 9).

Duas formas de configurar o Alertmanager:

- **Opção A, configuração global nos values do add-on (recomendada).** Casa alertas de qualquer namespace. Seções 1, 5, 6.
- **Opção B, `AlertmanagerConfig` com namespace.** O Prometheus Operator adiciona `namespace=<namespace da config>` a toda
  rota, então uma config em `cattle-monitoring-system` só captura alertas com esse namespace. Seção 7.

As duas opções ficam em telas diferentes da UI e **não são equivalentes**:

| Tela | O que edita | Alertas que enxerga |
|---|---|---|
| Advanced -> Addons -> rancher-monitoring -> Edit YAML | A configuração global do Alertmanager (Opção A) | Todos os namespaces, inclusive PVC e Longhorn |
| Monitoring & Logging -> Monitoring -> Alertmanager Configurations | Um objeto `AlertmanagerConfig` com namespace (Opção B) | Somente alertas daquele namespace |

Tudo que for criado na segunda tela é Opção B. Alertas de PVC e de Longhorn não carregam o namespace da config, então
caem em `null` **sem nenhum aviso**, mesmo que a config apareça como criada e válida. Por isso essa tela serve bem para um
namespace ou uma aplicação, mas não para alertas de capacidade e de saúde do cluster. Configs já criadas ali podem
continuar; apenas não cobrem esses alertas (a menos que se aplique o fragmento de matcher strategy da seção 7.3). A
[página de Monitoring](https://documentation.suse.com/cloudnative/virtualization/v1.8/en/observability/monitoring.html)
da própria SUSE (em inglês) registra a mesma restrição: o `AlertmanagerConfig` é restrito por namespace, e configurações
globais não são suportadas nessa tela.

## 3. Estado padrão e alertas embutidos

- O add-on `rancher-monitoring` vem habilitado em instalações novas (Advanced -> Addons).
- A configuração padrão do Alertmanager roteia **tudo para `null`**; o `Watchdog` também vai para `null`.
  Os values do add-on contêm apenas `alertmanager.config.global.resolve_timeout: 5m`.
- Não existem objetos `AlertmanagerConfig` nem silêncios (silences).
- As `inhibit_rules` padrão do chart continuam ativas (por exemplo, um alerta crítico suprime o aviso correspondente
  no mesmo namespace e com o mesmo nome de alerta).

### Alertas predefinidos relevantes para capacidade

São as regras padrão do kube-prometheus, confirmadas em um laboratório 1.8.2 (156 regras de alerta no total).

| Alerta | Significado |
|---|---|
| `KubePersistentVolumeFillingUp` (warning/critical) | Um PVC está quase cheio ou deve encher em breve |
| `KubePersistentVolumeInodesFillingUp` | O mesmo, para inodes |
| `KubePersistentVolumeErrors` (critical) | Um PV está em estado de erro |
| `NodeFilesystemSpaceFillingUp` / `NodeFilesystemAlmostOutOfSpace` | Um filesystem do host deve encher / está quase cheio |
| `NodeFilesystemFilesFillingUp` / `NodeFilesystemAlmostOutOfFiles` | Equivalentes de inodes para filesystems do host |
| `NodeMemoryHighUtilization` | RAM do host quase esgotada |
| `KubeCPUOvercommit`, `KubeMemoryOvercommit` | Mais CPU/RAM solicitada do que o cluster absorveria após perder um nó |
| `KubeCPUQuotaOvercommit`, `KubeMemoryQuotaOvercommit` | O mesmo, em relação às quotas de namespace |
| `KubeNodeNotReady`, `KubeletDown`, `TargetDown` | Saúde de nós e de coleta |
| `Watchdog` | Dispara sempre, de propósito; prova que o pipeline funciona. Mantenha-o em `null` |

**Lacuna:** nenhuma regra padrão monitora o **uso de disco do Longhorn**, que é o pool de armazenamento das VMs. As métricas
existem (`longhorn_disk_usage_bytes`, `longhorn_disk_capacity_bytes`, `longhorn_node_storage_*`); adicione a regra
personalizada da seção 8.

## 4. Antes de começar

1. **Add-on saudável.** Advanced -> Addons: `rancher-monitoring` está *Deploy Successful*.

   ![Página de add-ons com rancher-monitoring em Deploy Successful](docs/images/addons-rancher-monitoring.png)

2. **Veja a configuração atual.** Abra o Edit YAML do add-on e leia `alertmanager.config`. Se o cliente já tiver rotas
   ou receivers ali, mescle-os no novo bloco em vez de substituí-los.
3. **Reúna com o cliente:** host e porta do relay SMTP, modo TLS, se exige login, endereço do remetente (alguns relays só
   aceitam remetentes conhecidos), lista de destinatários. Confirme que os pods do Harvester alcançam o relay (firewall).
4. **Veja o que está disparando agora** (seção 9) para que a primeira rajada de emails não seja surpresa.
5. **Faça backup** dos values do add-on (copie o YAML do editor). O script faz isso automaticamente.

## 5. Receitas (Opção A, values do add-on)

Todas as receitas substituem a seção `config:` como descrito na seção 1. Escolha uma e ajuste os valores de exemplo.
Cada arquivo em `examples/addon-values/` é um fragmento `alertmanager:` completo.

### 5.1 Email com tudo

`examples/addon-values/01-email-everything.yaml`: o bloco do início rápido acima.

### 5.2 Email apenas de alertas de capacidade

Casa alertas de armazenamento, filesystem, overcommit e memória, mais as regras Longhorn personalizadas da seção 8.
É a melhor opção para "avise quando a capacidade for um problema".

```yaml
# Email only capacity-related alerts (storage, filesystem, CPU/memory overcommit,
# plus the custom Longhorn rules from examples/prometheus-rules/longhorn-capacity.yaml).
# [pt-BR] Envia por email apenas alertas de capacidade (armazenamento, filesystem, overcommit de CPU/memória
# e as regras Longhorn de examples/prometheus-rules/longhorn-capacity.yaml).
alertmanager:
  config:
    global:
      resolve_timeout: 5m
      smtp_smarthost: "smtp.customer.com:587"
      smtp_from: "harvester-alerts@customer.com"
      smtp_auth_username: "harvester-alerts@customer.com"
      smtp_auth_password: 'PASSWORD'
      smtp_require_tls: true
    route:
      receiver: "null"
      group_by: [alertname, namespace]
      routes:
        - receiver: "null"
          matchers: ['alertname=~"Watchdog|InfoInhibitor"']
        - receiver: email-ops
          repeat_interval: 4h
          matchers: ['alertname=~"KubePersistentVolume.*|NodeFilesystem.*|KubeCPUOvercommit|KubeMemoryOvercommit|KubeCPUQuotaOvercommit|KubeMemoryQuotaOvercommit|NodeMemoryHighUtilization|CustomStorageCapacity.*"']
    receivers:
      - name: "null"
      - name: email-ops
        email_configs:
          - to: "ops@customer.com"
            send_resolved: true
```

### 5.3 Email apenas de alertas críticos

A configuração mais silenciosa que ainda é útil.

```yaml
# Email only critical alerts (quietest useful setting).
# [pt-BR] Envia por email apenas alertas críticos (a configuração mais silenciosa que ainda é útil).
alertmanager:
  config:
    global:
      resolve_timeout: 5m
      smtp_smarthost: "smtp.customer.com:587"
      smtp_from: "harvester-alerts@customer.com"
      smtp_auth_username: "harvester-alerts@customer.com"
      smtp_auth_password: 'PASSWORD'
      smtp_require_tls: true
    route:
      receiver: "null"
      group_by: [alertname, namespace]
      routes:
        - receiver: "null"
          matchers: ['alertname=~"Watchdog|InfoInhibitor"']
        - receiver: email-ops
          repeat_interval: 4h
          matchers: ['severity="critical"']
    receivers:
      - name: "null"
      - name: email-ops
        email_configs:
          - to: "ops@customer.com"
            send_resolved: true
```

### 5.4 Vários destinatários

```yaml
# Same as 01, mailing several addresses. Each `to` entry sends its own message.
# (Alternatively, one entry with a comma separated `to: "a@x.com, b@x.com"` also works.)
# [pt-BR] Igual ao 01, enviando para vários endereços. Cada entrada `to` envia uma mensagem própria.
# (Também funciona uma única entrada com `to: "a@x.com, b@x.com"`.)
alertmanager:
  config:
    global:
      resolve_timeout: 5m
      smtp_smarthost: "smtp.customer.com:587"
      smtp_from: "harvester-alerts@customer.com"
      smtp_auth_username: "harvester-alerts@customer.com"
      smtp_auth_password: 'PASSWORD'
      smtp_require_tls: true
    route:
      receiver: "null"
      group_by: [alertname, namespace]
      routes:
        - receiver: "null"
          matchers: ['alertname=~"Watchdog|InfoInhibitor"']
        - receiver: email-ops
          repeat_interval: 4h
          matchers: ['alertname=~".+"']
    receivers:
      - name: "null"
      - name: email-ops
        email_configs:
          - to: "ops@customer.com"
            send_resolved: true
          - to: "storage-team@customer.com"
            send_resolved: true
```

### 5.5 Relay sem login nem TLS

```yaml
# SMTP relay that needs no login and no TLS (typical internal relay on port 25).
# Note: the sender address must still be accepted by the relay.
# [pt-BR] Relay SMTP sem login e sem TLS (típico de relay interno na porta 25).
# Observação: o remetente ainda precisa ser aceito pelo relay.
alertmanager:
  config:
    global:
      resolve_timeout: 5m
      smtp_smarthost: "relay.customer.local:25"
      smtp_from: "harvester-alerts@customer.local"
      smtp_require_tls: false
    route:
      receiver: "null"
      group_by: [alertname, namespace]
      routes:
        - receiver: "null"
          matchers: ['alertname=~"Watchdog|InfoInhibitor"']
        - receiver: email-ops
          repeat_interval: 4h
          matchers: ['alertname=~".+"']
    receivers:
      - name: "null"
      - name: email-ops
        email_configs:
          - to: "ops@customer.local"
            send_resolved: true
```

### 5.6 Endereços diferentes para crítico e warning

Críticos vão para o plantão a cada hora, avisos para a equipe a cada 12 horas.

```yaml
# Critical alerts go to the on-call address (reminded every hour),
# warnings go to the team mailbox (reminded every 12 hours).
# [pt-BR] Alertas críticos vão para o plantão (lembrete a cada hora);
# avisos (warning) vão para a caixa da equipe (lembrete a cada 12 horas).
alertmanager:
  config:
    global:
      resolve_timeout: 5m
      smtp_smarthost: "smtp.customer.com:587"
      smtp_from: "harvester-alerts@customer.com"
      smtp_auth_username: "harvester-alerts@customer.com"
      smtp_auth_password: 'PASSWORD'
      smtp_require_tls: true
    route:
      receiver: "null"
      group_by: [alertname, namespace]
      routes:
        - receiver: "null"
          matchers: ['alertname=~"Watchdog|InfoInhibitor"']
        - receiver: email-oncall
          repeat_interval: 1h
          matchers: ['severity="critical"']
        - receiver: email-team
          repeat_interval: 12h
          matchers: ['severity="warning"']
    receivers:
      - name: "null"
      - name: email-oncall
        email_configs:
          - to: "oncall@customer.com"
            send_resolved: true
      - name: email-team
        email_configs:
          - to: "team@customer.com"
            send_resolved: true
```

### 5.7 Webhook no lugar de email

Qualquer sistema que aceite um HTTP POST com o JSON do Alertmanager.

```yaml
# "Anything, not just email": POST every alert as JSON to a webhook
# (Alertmanager webhook payload format; works with many chat/ticket bridges).
# [pt-BR] "Qualquer destino, não só email": envia cada alerta como JSON (formato de webhook do Alertmanager)
# para uma URL; funciona com várias pontes de chat/tickets.
alertmanager:
  config:
    global:
      resolve_timeout: 5m
    route:
      receiver: "null"
      group_by: [alertname, namespace]
      routes:
        - receiver: "null"
          matchers: ['alertname=~"Watchdog|InfoInhibitor"']
        - receiver: webhook-ops
          repeat_interval: 4h
          matchers: ['alertname=~".+"']
    receivers:
      - name: "null"
      - name: webhook-ops
        webhook_configs:
          - url: "https://alerts.customer.com/hooks/harvester"
            send_resolved: true
```

### 5.8 Slack

```yaml
# Slack incoming webhook instead of email.
# [pt-BR] Webhook de entrada do Slack no lugar de email.
alertmanager:
  config:
    global:
      resolve_timeout: 5m
    route:
      receiver: "null"
      group_by: [alertname, namespace]
      routes:
        - receiver: "null"
          matchers: ['alertname=~"Watchdog|InfoInhibitor"']
        - receiver: slack-ops
          repeat_interval: 4h
          matchers: ['alertname=~".+"']
    receivers:
      - name: "null"
      - name: slack-ops
        slack_configs:
          - api_url: "https://hooks.slack.com/services/T000/B000/XXXX"
            channel: "#harvester-alerts"
            send_resolved: true
            title: '{{ .Status | toUpper }}: {{ .CommonLabels.alertname }}'
            text: '{{ range .Alerts }}{{ .Annotations.summary }}{{ "\n" }}{{ end }}'
```

### Ajustando a rota

| Quero | Altere |
|---|---|
| Menos emails repetidos para alertas que continuam disparando | aumente `repeat_interval` (nos exemplos: 4h) |
| Apenas alguns alertas | edite a regex `alertname=~"..."` (`|` separa nomes, `.*` é curinga) |
| Apenas uma severidade | `matchers: ['severity="critical"']` (ou `warning`) |
| Um email por alerta em vez de emails agrupados | `group_by: [alertname, namespace, instance]` |
| Esperar mais para agrupar uma tempestade de alertas | adicione `group_wait: 2m` à rota |
| Excluir um alerta ruidoso de "tudo" | adicione uma rota *antes* da rota de email: `- receiver: "null"` com `matchers: ['alertname="OAlertaRuidoso"']` |

Os matchers são avaliados de cima para baixo; a primeira rota que casa vence (a menos que haja `continue: true`).
Mantenha a rota `Watchdog|InfoInhibitor` em primeiro lugar.

## 6. Usando o script

O `harvester-alert-email.sh` pergunta os valores e aplica qualquer uma das opções. Execute-o no **Kubectl Shell** da UI
(o ícone `>_` na barra superior; cole o script em um arquivo com `cat > a.sh` e finalize com Ctrl-D) ou em um nó do Harvester.

```bash
bash harvester-alert-email.sh --dry-run   # validação no servidor, nada é gravado
bash harvester-alert-email.sh             # execução real
```

- O **modo 1** altera os values do add-on com uma configuração global (mesmo resultado das receitas). Antes, salva os
  values atuais em `./addon-rancher-monitoring-values.backup.<timestamp>.yaml`, avisa quando vai substituir um
  `alertmanager.config` existente e preserva todas as outras chaves.
- O **modo 2** cria o `AlertmanagerConfig` com namespace e o Secret (seção 7).
- Ambos podem adicionar a regra personalizada do Longhorn (seção 8).
- Para enviar **tudo** por email, responda `.+` no prompt "Alert names to email". A regex padrão é o conjunto de capacidade da receita 5.2.
- Os prompts do script estão em inglês.

Sessão de exemplo (os valores são ilustrativos):

```text
== Harvester Alertmanager email setup ==
1) Global config in the add-on values (recommended)
2) Namespaced AlertmanagerConfig object
Mode [1]: 1
SMTP server host [smtp.example.com]: smtp.customer.com
SMTP server port [587]: 587
Sender (From) address: harvester-alerts@customer.com
Recipient address(es), comma separated: ops@customer.com, storage-team@customer.com
SMTP username (empty = no auth): harvester-alerts@customer.com
SMTP password:
Require TLS (STARTTLS)? [Y/n]: Y
Repeat interval for unresolved alerts [4h]: 4h
Alert names to email (regex) [KubePersistentVolume.*|NodeFilesystem.*|...]: .+
Also add Longhorn disk usage alerts (80% warn / 90% crit)? [Y/n]: Y

Summary: mode 1 | smtp smtp.customer.com:587 | from harvester-alerts@customer.com | to ops@customer.com storage-team@customer.com | auth harvester-alerts@customer.com | tls true
Proceed? [Y/n]: Y
Backed up current add-on values to ./addon-rancher-monitoring-values.backup.20261028-101500.yaml
NOTE: the add-on already has an alertmanager.config; it will be REPLACED (backup above).
addon.harvesterhci.io/rancher-monitoring patched
Add-on patched. It redeploys in a minute or two; check Advanced -> Addons -> rancher-monitoring.
prometheusrule.monitoring.coreos.com/harvester-capacity created
Done.
```

O arquivo de backup contém os values do add-on; ele não contém a nova senha, mas trate-o como sensível se os values
antigos já o eram. O `.gitignore` deste repositório já ignora esses arquivos.

## 7. Opção B: um AlertmanagerConfig com namespace

Use quando editar os values do add-on não for aceitável. Funciona pela página **Monitoring & Logging -> Monitoring ->
Alertmanager Configurations**, com duas peculiaridades da UI vistas no laboratório:

- a lista de namespaces **não mostra `cattle-monitoring-system`**;
- **Add Receiver fica desabilitado** no formulário de criação.

Ambas são contornadas com **Edit as YAML** (barra inferior do formulário), onde você digita o namespace.

![Formulário de criação de Alertmanager Configuration com Add Receiver desabilitado](docs/images/alertmanager-config-create.png)

**Limitação.** O operator adiciona `namespace="cattle-monitoring-system"` à rota, então só casam alertas com esse
namespace (ex.: `NodeFilesystem*`, `NodeMemoryHighUtilization`). Alertas de PVC (namespace do PVC) e de Longhorn
(`namespace=longhorn-system`) **não** casam, o que foi confirmado no laboratório. Use a Opção A, ou remova a restrição
com o fragmento de 7.3.

### 7.1 Secret SMTP (dispensável para um relay sem login)

Crie-o primeiro (Advanced -> Secrets -> Create -> Edit as YAML).

```yaml
# SMTP password for the namespaced AlertmanagerConfig (Option B).
# Create via Advanced -> Secrets -> Create -> Edit as YAML.
# [pt-BR] Senha SMTP para o AlertmanagerConfig com namespace (Opção B).
# Crie em Advanced -> Secrets -> Create -> Edit as YAML.
apiVersion: v1
kind: Secret
metadata:
  name: smtp-auth
  namespace: cattle-monitoring-system
type: Opaque
stringData:
  password: "PASSWORD"
```

### 7.2 A configuração

```yaml
# Option B: namespaced AlertmanagerConfig.
# LIMITATION: the Prometheus Operator adds namespace="cattle-monitoring-system" to the route,
# so only alerts carrying that namespace match (e.g. NodeFilesystem*, NodeMemoryHighUtilization).
# PVC alerts (namespace of the PVC) and Longhorn alerts (namespace=longhorn-system) do NOT match,
# unless alertmanager.alertmanagerSpec.alertmanagerConfigMatcherStrategy.type is set to None
# in the add-on values (see 03-matcher-strategy-none.yaml).
# Create via Monitoring & Logging -> Monitoring -> Alertmanager Configurations -> Create -> Edit as YAML.
# [pt-BR] Opção B: AlertmanagerConfig com namespace.
# LIMITAÇÃO: o Prometheus Operator adiciona namespace="cattle-monitoring-system" à rota, então só casam alertas
# com esse namespace (ex.: NodeFilesystem*, NodeMemoryHighUtilization). Alertas de PVC (namespace do PVC) e de
# Longhorn (namespace=longhorn-system) NÃO casam, a menos que alertmanagerConfigMatcherStrategy.type seja None
# nos values do add-on (veja 03-matcher-strategy-none.yaml).
# Crie em Monitoring & Logging -> Monitoring -> Alertmanager Configurations -> Create -> Edit as YAML.
apiVersion: monitoring.coreos.com/v1alpha1
kind: AlertmanagerConfig
metadata:
  name: capacity-email
  namespace: cattle-monitoring-system
spec:
  route:
    receiver: email-ops
    groupBy: [alertname]
    groupWait: 30s
    groupInterval: 5m
    repeatInterval: 4h
    matchers:
      - name: alertname
        matchType: =~
        value: "NodeFilesystem.*|KubeCPUOvercommit|KubeMemoryOvercommit|NodeMemoryHighUtilization"
  receivers:
    - name: email-ops
      emailConfigs:
        - to: "ops@customer.com"
          from: "harvester-alerts@customer.com"
          smarthost: "smtp.customer.com:587"
          authUsername: "harvester-alerts@customer.com"
          authPassword:
            name: smtp-auth
            key: password
          requireTLS: true
          sendResolved: true
```

### 7.3 Fazer casar todos os namespaces

```yaml
# Add-on values fragment (Advanced -> Addons -> rancher-monitoring -> Edit YAML).
# Makes namespaced AlertmanagerConfig objects match alerts from ALL namespaces.
# Merge into the existing `alertmanager.alertmanagerSpec:` block; do not duplicate keys.
# [pt-BR] Fragmento dos values do add-on. Faz os AlertmanagerConfig com namespace casarem alertas de TODOS os
# namespaces. Mescle no bloco `alertmanager.alertmanagerSpec:` existente; não duplique chaves.
alertmanager:
  alertmanagerSpec:
    alertmanagerConfigMatcherStrategy:
      type: None
```

Mescle no bloco `alertmanager.alertmanagerSpec:` existente nos values do add-on. O Prometheus Operator da 1.8.2 (v0.85)
suporta esse campo. Depois que o add-on for reimplantado, amplie a regex de `value:` em 7.2 conforme necessário.

## 8. Alertas de capacidade do Longhorn

`examples/prometheus-rules/longhorn-capacity.yaml` gera um aviso aos 80% e um alerta crítico aos 90% de uso de disco do
Longhorn; ajuste os limites ao seu gosto.

```yaml
# Custom rule: stock rules do not watch Longhorn disk usage (the VM storage pool).
# Apply from the UI's Kubectl Shell:  kubectl apply -f longhorn-capacity.yaml
# These alerts carry namespace=longhorn-system, so they need the global config
# (addon-values examples) or matcher strategy None.
# [pt-BR] Regra personalizada: as regras padrão não monitoram o uso de disco do Longhorn (o pool de
# armazenamento das VMs). Aplique no Kubectl Shell da UI: kubectl apply -f longhorn-capacity.yaml
# Esses alertas têm namespace=longhorn-system; use a configuração global (exemplos addon-values) ou matcher strategy None.
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: harvester-capacity
  namespace: cattle-monitoring-system
  labels:
    release: rancher-monitoring
spec:
  groups:
    - name: harvester-capacity
      rules:
        - alert: CustomStorageCapacityWarning
          expr: (longhorn_disk_usage_bytes / longhorn_disk_capacity_bytes) > 0.80
          for: 10m
          labels: {severity: warning}
          annotations:
            summary: "Longhorn disk {{ $labels.disk }} on {{ $labels.node }} above 80%"
        - alert: CustomStorageCapacityCritical
          expr: (longhorn_disk_usage_bytes / longhorn_disk_capacity_bytes) > 0.90
          for: 5m
          labels: {severity: critical}
          annotations:
            summary: "Longhorn disk {{ $labels.disk }} on {{ $labels.node }} above 90%"
```

Aplique-o pelo Kubectl Shell da UI (`kubectl apply -f longhorn-capacity.yaml`), ou deixe o script fazer isso.
A métrica e seus labels `disk`, `node` e `namespace` foram confirmados no laboratório. Os limites de agendamento do
próprio Longhorn (Storage Over Provisioning Percentage, Storage Minimal Available Percentage) são independentes; alerte antes que eles atuem.

## 9. Visualizando alertas e verificando a entrega

### 9.1 Na UI: menu Alerting do Grafana

Abra o Grafana pelo painel do Harvester e vá em **Alerting**:

- **Active notifications**: o que está disparando agora e para qual receiver cada alerta é "Delivered to". `null` significa
  descartado hoje; `email-ops` (ou o nome do seu receiver) significa enviado por email. Confira antes e depois de aplicar.

![Grafana Alerting, Active notifications, mostrando o receiver de cada alerta ativo](docs/images/grafana-active-notifications.png)

  (A captura é de um laboratório que já roteia seus alertas personalizados `Harvester*` para um receiver de email; uma
  instalação padrão mostra `null`.)

- **Alert rules**: as definições das regras, padrão e personalizadas.
- **Silences**: silêncios que suprimiriam emails (nenhum em uma instalação padrão).

### 9.2 Alternativa: pelo proxy da API do Kubernetes

Logado no Harvester, abra (o próprio add-on usa este formato de URL no `externalUrl`):

- Alertas do Prometheus: `https://<harvester>/api/v1/namespaces/cattle-monitoring-system/services/http:rancher-monitoring-prometheus:9090/proxy/alerts`
- Alertmanager (a página **Status** mostra a configuração realmente carregada): `https://<harvester>/api/v1/namespaces/cattle-monitoring-system/services/http:rancher-monitoring-alertmanager:9093/proxy/`

Pelo Kubectl Shell, liste os nomes de todos os alertas:

```bash
kubectl -n cattle-monitoring-system get prometheusrule -o json \
  | jq -r '.items[].spec.groups[].rules[] | select(.alert) | .alert' | sort -u
```

### 9.3 Teste ponta a ponta

Aplique um alerta temporário que dispara sempre, aguarde cerca de um minuto (30 s de `group_wait` mais a avaliação),
espere o email e então apague o alerta.

```yaml
# TEMPORARY always-firing alert to prove end-to-end delivery. Delete it afterwards:
#   kubectl -n cattle-monitoring-system delete prometheusrule email-test
# Name starts with CustomStorageCapacity so it matches the capacity-only examples;
# with the "email everything" example any name matches.
# [pt-BR] Alerta TEMPORÁRIO que dispara sempre, para provar a entrega ponta a ponta. Apague depois:
#   kubectl -n cattle-monitoring-system delete prometheusrule email-test
# O nome começa com CustomStorageCapacity, então casa com os exemplos de capacidade e com os de "tudo".
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: email-test
  namespace: cattle-monitoring-system
  labels:
    release: rancher-monitoring
spec:
  groups:
    - name: email-test
      rules:
        - alert: CustomStorageCapacityEmailTest
          expr: vector(1)
          labels:
            severity: warning
            namespace: cattle-monitoring-system
          annotations:
            summary: "Test alert: if you received this email, Alertmanager delivery works."
```

```bash
kubectl apply -f test-alert.yaml
# ... o email chega ...
kubectl -n cattle-monitoring-system delete prometheusrule email-test
```

O nome do alerta de teste começa com `CustomStorageCapacity`, então casa com a receita 5.2 e com as receitas de "tudo".
Ele tem `namespace=cattle-monitoring-system`, então também casa com o exemplo da Opção B. No teste do laboratório, um alerta
com outro namespace *não* foi entregue por uma config com namespace, como esperado.

## 10. Solução de problemas

| Sintoma | Causa provável e correção |
|---|---|
| Salvar no Edit YAML falha ou o add-on fica em *Deploying* | Chave `alertmanager:` duplicada ou indentação errada. Restaure o backup e aplique de novo com o bloco sob a chave existente |
| Grafana -> Active notifications ainda diz "Delivered to null" | O add-on ainda não foi reimplantado (aguarde), ou a regex da rota não casa com o nome do alerta; corrija o matcher `alertname=~` |
| A página Status do Alertmanager não mostra seu receiver | A configuração não foi carregada: veja os logs do pod do Alertmanager por erro de configuração |
| Receiver carregado, o alerta mostra o receiver, mas não chega email | Problema de SMTP; leia os logs (abaixo) |
| `535` / falha de autenticação | `smtp_auth_username`/senha incorretos, ou o relay exige uma senha de aplicativo |
| Erros `x509` / TLS | O relay usa uma CA privada, ou `smtp_require_tls` não combina com a porta (587 exige `true`; 25 interna costuma ser `false`) |
| `connection refused` / timeout | Firewall ou host/porta errados; teste de um nó: `nc -vz smtp.customer.com 587` |
| `554` / remetente rejeitado | O relay não permite o `smtp_from` |
| Alertas de PVC não chegam com a Opção B | Esperado; veja a limitação da seção 7, use a Opção A |
| O alerta chega uma vez e depois silêncio | É o `repeat_interval` (padrão 4h) funcionando como projetado |
| Enxurrada de emails | Restrinja a regex ou a severidade (seção 5), aumente o `repeat_interval` |

Logs:

```bash
kubectl -n cattle-monitoring-system logs alertmanager-rancher-monitoring-alertmanager-0 -c alertmanager \
  | grep -i -E 'smtp|notify|error'
```

## 11. Reversão

- **Opção A / modo 1 do script:** cole de volta o bloco `config:` original (ou o arquivo de backup gravado pelo script) em
  Advanced -> Addons -> `rancher-monitoring` -> Edit YAML.
- **Opção B:** apague o `AlertmanagerConfig` e o Secret `smtp-auth` na UI.
- **Regra personalizada / alerta de teste:** `kubectl -n cattle-monitoring-system delete prometheusrule harvester-capacity email-test`.

## 12. O que foi testado

Testado em um laboratório Harvester 1.8.2 (Prometheus Operator v0.85, Alertmanager 0.28.1):

- Nomes dos alertas, a métrica do Longhorn e seus labels, o caminho do proxy, a estrutura dos values do add-on e os
  endpoints de secret/status do Alertmanager foram lidos do cluster.
- **Script, modo 2, execução real:** criou o Secret, o `AlertmanagerConfig` e a regra; o Alertmanager os carregou (o matcher
  de namespace injetado ficou visível na configuração carregada); um alerta de teste foi entregue a um captador SMTP no
  cluster, com autenticação e sem TLS; um alerta com outro namespace foi roteado para `null` e não foi entregue; as regras
  do Longhorn foram avaliadas com saúde `ok`. Tudo foi apagado depois.
- **Script, ambos os modos, `--dry-run`:** o servidor da API aceitou todos os objetos; confirmou-se que o add-on real
  ficou inalterado. Os values gerados do add-on foram comparados e interpretados; senhas com `'`, `"` e `\` fazem o ciclo
  completo corretamente; a edição trata a ausência da chave `config:`, a ausência do bloco `alertmanager:` e `config:` no
  fim do arquivo.
- **Todos os arquivos de `examples/`:** CRs e regras aceitos pelo servidor da API (dry-run no servidor); cada fragmento
  de add-on mesclado aos values reais e aceito por um patch em dry-run no servidor; cada configuração do Alertmanager
  carregada por um pod Alertmanager 0.28.1 descartável usando a imagem do próprio cluster (uma configuração
  propositalmente quebrada foi rejeitada, então a verificação discrimina).
