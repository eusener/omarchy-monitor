# Omarchy Monitor

Extensão do **painel padrão completo** do Omarchy Shell com o editor avançado `eusener.displays`.

A base conserva as propriedades e os métodos do plugin original, além de brilho, tamanho do texto, presets rápidos de escala (1, 1,25, 1,6, 2, 3 e 4×, conforme os modos suportados), lista de monitores, roda do mouse e IPC. O editor avançado aparece abaixo no mesmo painel, com resolução, Hz, modos personalizados, VRR, rotação, espelhamento, HDR, cor, monitor principal e mapa de arranjo.

## Instalação pelo GitHub

```bash
omarchy plugin add https://github.com/eusener/omarchy-monitor.git --enable
```

Se já usa a cópia local `eusener.displays`, mantenha a instalação local ou guarde suas customizações antes de migrar: o instalador do Omarchy recusa identificadores duplicados.

## Instalação local

```bash
python3 scripts/install.py
```

O instalador valida o manifesto, faz backup em `~/.config/omarchy/backups/monitor-<data>/`, liga `~/.config/omarchy/plugins/eusener.displays` a este projeto e mantém uma única entrada na barra. As demais configurações são preservadas. Se mover a pasta do projeto, execute o instalador novamente.

O identificador `eusener.displays`, o atalho **Super+Ctrl+F7** já configurado e as notificações anteriores continuam funcionando. O manifesto declara `clonedFrom: omarchy.monitor` e carrega uma cópia de `Monitor.qml` em um diretório de runtime identificado pelo conteúdo. Nenhum arquivo de `/usr/share/omarchy/` é alterado.

A configuração e os plugins recarregam automaticamente. Quando necessário, na sessão gráfica:

```bash
omarchy-shell shell rescanPlugins
```

## Uso

Brilho e tamanho do texto são imediatos, como no painel original. Os presets rápidos de escala aplicam uma prévia protegida pelo watchdog do editor; confirme em **Manter** em até 15 segundos ou a configuração anterior volta. Os controles de monitores externos seguem o mesmo caminho. O interruptor da tela interna usa o comando do Omarchy, como antes.

Os ajustes do editor ficam em rascunho até **Aplicar**. Enquanto há rascunho ou confirmação pendente, os controles rápidos de escala e monitores ficam indisponíveis para evitar ações concorrentes. Os perfis continuam em `~/.config/omarchy/displays/profiles.json`, renderizados em `~/.config/hypr/displays.lua`, seguindo a descrição EDID entre portas e docks.

As setas/hjkl mantêm a navegação padrão de brilho, texto, escala e lista de monitores, chegando ao editor avançado no final. No editor, h/l muda o monitor e j/k rola; Enter aplica/mantém e u reverte. Campos e listas usam sua própria navegação. Esc fecha e Tab troca de painel.

## Código

- `scripts/build-runtime.py`: gera a cópia de runtime e atualiza a entrada do manifesto para evitar cache antigo no shell.
- `Monitor.qml`: entrada que herda o painel padrão e conecta o editor avançado.
- `NativeMonitor.qml`: cópia completa de `plugins/panels/monitor/Panel.qml`, com ponto de extensão, limites do popup e integração de teclado/rolagem.
- `Model.js`: modelo padrão do Omarchy, sem alterações.
- `DisplayEditor.qml`: estado e conteúdo do editor personalizado existente.
- `displays.py`, `Layout.js`: perfis, aplicação, watchdog e cálculos. O helper permite preservar uma tela interna já desligada ao alterar uma externa.
- `BarWidget.qml`: entrada de compatibilidade que delega para `Monitor.qml`.

Desenvolvido para Omarchy Shell 4.5 com `qs.Ui`, `qs.Commons`, Python 3 e Hyprland com configuração Lua. Atualizações do Omarchy podem exigir atualizar a cópia da base.

## Testes

```bash
./scripts/check.sh
```

O comando também empacota o runtime. Depois de editar os fontes, execute-o antes de recarregar o plugin. Testa os modelos, a instalação e o carregamento/controles Qt com uma tela, duas telas e laptop desligado. O teste Qt usa comandos simulados e substitui apenas a janela layer-shell por um host offscreen. Valida propriedades/métodos originais, IPC antigo e padrão, controles visíveis, prévia de escala, navegação e posição da confirmação.

Efeitos físicos de brilho, HDR/VRR e monitores, além da geometria da janela Wayland, exigem validação na sessão gráfica.
