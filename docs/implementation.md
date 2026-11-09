# Integração do monitor — versão 1.2.0

Pedido: estender o plugin original completo com o customizado, preservando as propriedades originais, e salvar em Projects.

A versão 1.1 só incorporava controles de brilho/texto ao editor personalizado. Foi substituída por herança: Monitor.qml usa NativeMonitor.qml (Panel.qml original completo com slot de extensão), Model.js original e DisplayEditor.qml como editor adicional.

Validação: scripts/check.sh passou, com 8 testes Python (incluindo Qt com uma tela, duas telas e laptop desligado), suítes Node, manifesto e sintaxe QML. A revisão detectou e os testes reproduziram duas regressões corrigidas: a confirmação rolava ao rodapé da extensão; aplicar escala externa rejeitava uma tela interna previamente desligada.

Backup anterior à correção: ~/.config/omarchy/backups/monitor-native-base-20261108-195242/.

O shell rejeitou a mudança de entrada no mesmo diretório com File name case mismatch. A entrada agora usa runtime/v_1_2_0_<hash>/Monitor.qml; scripts/build-runtime.py gera URLs imutáveis por conteúdo, e os testes Qt carregam o pacote gerado. A instalação local permanece ligada a ~/Projects/omarchy-monitor; a recarga é disparada pelo observador do diretório de plugins.

O ambiente permite ler o log do shell, mas nega seu IPC e o acesso à sessão Wayland. Testes offscreen validam o conteúdo e os contratos; não comprovam o efeito no hardware.
