object FormInIOCPShortConnection: TFormInIOCPShortConnection
  Left = 0
  Top = 0
  Caption = 'InIOCP '#30701#36830#25509#24212#29992
  ClientHeight = 473
  ClientWidth = 750
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -12
  Font.Name = #23435#20307
  Font.Style = []
  OldCreateOrder = False
  Position = poDesktopCenter
  Scaled = False
  OnCreate = FormCreate
  PixelsPerInch = 96
  TextHeight = 12
  object lbl1: TLabel
    Left = 591
    Top = 31
    Width = 36
    Height = 12
    Caption = #31471#21475#65306
  end
  object Memo1: TMemo
    Left = 8
    Top = 212
    Width = 511
    Height = 253
    ImeName = #35895#27468#25340#38899#36755#20837#27861' 2'
    Lines.Strings = (
      '1'#12289#27979#35797#30701#36830#25509#65307
      '2'#12289#27599#27425#30331#24405#36820#22238#30340' Session '#30340#26377#25928#26399#20026' 30 '#20998#38047#65292
      '     '#25226' InConnection1 '#30340#23646#24615' ReuseSession '#35774#20026' True '#21363#21487#37325#22797#20351#29992#65307
      '3'#12289#20197#21518#21482#38656#36830#25509#12289#25191#34892#20219#21153#21363#21487#65292#26080#38656#21453#22797#30331#24405#12290)
    ScrollBars = ssBoth
    TabOrder = 0
    WordWrap = False
  end
  object btnStart: TButton
    Left = 591
    Top = 89
    Width = 75
    Height = 25
    Caption = #21551#21160
    TabOrder = 1
    OnClick = btnStartClick
  end
  object btnStop: TButton
    Left = 591
    Top = 130
    Width = 75
    Height = 25
    Caption = #20572#27490
    Enabled = False
    TabOrder = 2
    OnClick = btnStopClick
  end
  object btnConnect: TButton
    Left = 538
    Top = 236
    Width = 75
    Height = 25
    Caption = #36830#25509
    TabOrder = 3
    OnClick = btnConnectClick
  end
  object btnDisconnect: TButton
    Left = 538
    Top = 270
    Width = 75
    Height = 25
    Caption = #26029#24320
    TabOrder = 4
    OnClick = btnDisconnectClick
  end
  object btnSend: TButton
    Left = 645
    Top = 338
    Width = 75
    Height = 25
    Caption = #21457#36865
    TabOrder = 5
    OnClick = btnSendClick
  end
  object EditTarget: TEdit
    Left = 645
    Top = 303
    Width = 75
    Height = 20
    ImeName = #35895#27468#25340#38899#36755#20837#27861' 2'
    TabOrder = 6
  end
  object btnBroad: TButton
    Left = 645
    Top = 372
    Width = 75
    Height = 25
    Caption = #24191#25773
    TabOrder = 7
    OnClick = btnBroadClick
  end
  object btnLogin: TButton
    Left = 536
    Top = 338
    Width = 75
    Height = 25
    Caption = #30331#24405
    TabOrder = 8
    OnClick = btnLoginClick
  end
  object btnLogout: TButton
    Left = 536
    Top = 372
    Width = 75
    Height = 25
    Caption = #30331#20986
    TabOrder = 9
    OnClick = btnLogoutClick
  end
  object EditUserName: TEdit
    Left = 538
    Top = 303
    Width = 75
    Height = 20
    ImeName = #35895#27468#25340#38899#36755#20837#27861' 2'
    TabOrder = 10
    Text = 'USER_A'
    OnDblClick = EditUserNameDblClick
  end
  object edtPort: TEdit
    Left = 591
    Top = 52
    Width = 75
    Height = 20
    ImeName = #35895#27468#25340#38899#36755#20837#27861' 2'
    TabOrder = 11
    Text = '12302'
    OnDblClick = EditUserNameDblClick
  end
  object btnQuery: TButton
    Left = 536
    Top = 414
    Width = 75
    Height = 25
    Caption = #26597#35810
    TabOrder = 12
    OnClick = btnQueryClick
  end
  inline FrameIOCPSvrInfo1: TFrameIOCPSvrInfo
    Left = 8
    Top = 5
    Width = 547
    Height = 201
    Font.Charset = DEFAULT_CHARSET
    Font.Color = clWindowText
    Font.Height = -15
    Font.Name = #23435#20307
    Font.Style = []
    ParentFont = False
    TabOrder = 13
    ExplicitLeft = 8
    ExplicitTop = 5
    ExplicitWidth = 547
  end
  object Button1: TButton
    Left = 645
    Top = 414
    Width = 75
    Height = 25
    Caption = #21709#24212
    TabOrder = 14
    OnClick = Button1Click
  end
  object InIOCPServer1: TInIOCPServer
    IOCPManagers.ClientManager = InClientManager1
    IOCPManagers.MessageManager = InMessageManager1
    ServerAddr = '127.0.0.1'
    ThreadOptions.BusinessThreadCount = 8
    ThreadOptions.PushThreadCount = 4
    ThreadOptions.WorkThreadCount = 4
    AfterOpen = InIOCPServer1AfterOpen
    AfterClose = InIOCPServer1AfterClose
    Left = 160
    Top = 288
  end
  object InConnection1: TInConnection
    AutoConnect = True
    LocalPath = 'temp'
    ReuseSessionId = True
    ServerAddr = '127.0.0.1'
    OnReceiveMsg = InConnection1ReceiveMsg
    OnError = InConnection1Error
    Left = 160
    Top = 344
  end
  object InMessageManager1: TInMessageManager
    OnBroadcast = InMessageManager1Broadcast
    OnPush = InMessageManager1Push
    OnReceive = InMessageManager1Receive
    Left = 240
    Top = 288
  end
  object InMessageClient1: TInMessageClient
    OnReturnResult = InMessageClient1ReturnResult
    Connection = InConnection1
    Left = 240
    Top = 344
  end
  object InClientManager1: TInClientManager
    OnLogin = InClientManager1Login
    Left = 200
    Top = 288
  end
  object InCertifyClient1: TInCertifyClient
    Connection = InConnection1
    OnCertify = InCertifyClient1Certify
    OnListClients = InCertifyClient1ListClients
    Left = 200
    Top = 344
  end
  object InEchoClient1: TInEchoClient
    OnReturnResult = InEchoClient1ReturnResult
    Connection = InConnection1
    Left = 368
    Top = 344
  end
end
