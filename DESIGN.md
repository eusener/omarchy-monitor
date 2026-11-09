# Painel de monitores

Usar o painel padrão completo do Omarchy como base. NativeMonitor.qml preserva as propriedades, métodos, hero, brilho, texto, presets de escala, lista de monitores, IPC e navegação do Panel.qml instalado. Model.js permanece idêntico ao modelo padrão.

Monitor.qml herda essa base e anexa DisplayEditor.qml na mesma coluna de rolagem. O editor mantém arranjo, modos, VRR, HDR, cor, perfis e watchdog. Um único ícone abre tudo. O popup usa o limite da tela, largura preferida de 500 e altura máxima preferida de 760 unidades Style.space.

Proprietários canônicos: qs.Commons.Style, qs.Commons.Color, tema da barra e componentes qs.Ui. Não introduzir paleta ou tipografia paralela. O código nativo continua seguindo I18n; o editor usa Commons.Translations em inglês/português. Hardware e textos externos usam PlainText.

Brilho e texto preservam o comportamento imediato nativo. Os presets de escala e os controles externos usam o helper avançado e sua reversão de 15 segundos, mantendo uma única persistência dos perfis. Mudanças rápidas ficam indisponíveis durante rascunho/alteração pendente. O interruptor do laptop continua usando o comando Omarchy. Uma tela interna já desligada pode permanecer desligada enquanto um monitor externo muda.

A navegação nativa chega à seção avançada; campos e listas bloqueiam os atalhos globais enquanto ativos. A rolagem fica parada durante arraste do mapa. Ao abrir uma confirmação, posicionar o início da seção avançada, nunca seu rodapé.

Validação: scripts/check.sh testa o modelo, o layout, a instalação e o painel Qt com uma tela, duas telas e tela interna desligada. A janela layer-shell é substituída somente nos testes offscreen. Verificar visibilidade de brilho/texto/preset 4x/editor e contratos de propriedades/IPC; a inspeção em Qt offscreen não prova geometria Wayland ou efeito físico no hardware.
