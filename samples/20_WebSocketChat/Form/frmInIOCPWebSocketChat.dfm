object FormInIOCPWSChat: TFormInIOCPWSChat
  Left = 0
  Top = 0
  Caption = 'InIOCP WebSocket '#26381#21153
  ClientHeight = 436
  ClientWidth = 693
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -15
  Font.Name = #23435#20307
  Font.Style = []
  OldCreateOrder = False
  Position = poDesktopCenter
  OnCreate = FormCreate
  PixelsPerInch = 120
  TextHeight = 15
  object Button1: TButton
    Left = 600
    Top = 35
    Width = 75
    Height = 28
    Caption = #21551#21160
    TabOrder = 0
    OnClick = Button1Click
  end
  object Button2: TButton
    Left = 600
    Top = 83
    Width = 75
    Height = 28
    Caption = #20572#27490
    TabOrder = 1
    OnClick = Button2Click
  end
  object Memo1: TMemo
    Left = 8
    Top = 224
    Width = 570
    Height = 201
    ImeName = #35895#27468#25340#38899#36755#20837#27861' 2'
    Lines.Strings = (
      #22240#22686#21152#20102#26381#21153#31471#32452#20214' TInWebSocketManager'#65292#35831#37325#26032#32534#35793' InIOCP'#12290
      ''
      #35201#25226' TInHttpDataProvider '#21644' TInWebSocketManager '#20851#32852#36215#26469#65292
      ''
      #26412#20363#20013#21482#28436#31034' WebSocket '#30340#29992#27861#65292#22914#26524#27979#35797#22823#24182#21457#65292#35831#19981#35201#22312#31383#21475#26174#31034#28040#24687#65292
      ''
      #21487#20197#25171#24320#20197#19979#32593#31449#27979#35797' WebSocket '#25928#26524#65306
      'http://www.websocketest.com/'
      'http://www.blue-zero.com/WebSocket/')
    ScrollBars = ssBoth
    TabOrder = 2
  end
  inline FrameIOCPSvrInfo1: TFrameIOCPSvrInfo
    Left = 8
    Top = 8
    Width = 561
    Height = 201
    Font.Charset = DEFAULT_CHARSET
    Font.Color = clWindowText
    Font.Height = -15
    Font.Name = #23435#20307
    Font.Style = []
    ParentFont = False
    TabOrder = 3
    ExplicitLeft = 8
    ExplicitTop = 8
    ExplicitWidth = 561
    inherited Label3: TLabel
      Top = 28
      ExplicitTop = 28
    end
    inherited lblWorkCount: TLabel
      Top = 28
      ExplicitTop = 28
    end
    inherited bvl1: TBevel
      Top = 48
      Height = 1
      ExplicitTop = 48
      ExplicitHeight = 1
    end
    inherited lbl19: TLabel
      Top = 28
      ExplicitTop = 28
    end
    inherited lblAcceptExCnt: TLabel
      Left = 108
      ExplicitLeft = 108
    end
    inherited lblDataByteInfo: TLabel
      Left = 108
      ExplicitLeft = 108
    end
    inherited lblClientInfo: TLabel
      Left = 108
      Top = 58
      ExplicitLeft = 108
      ExplicitTop = 58
    end
    inherited lblCliPool: TLabel
      Top = 58
      ExplicitTop = 58
    end
    inherited lblIODataInfo: TLabel
      Left = 108
      ExplicitLeft = 108
    end
    inherited lblDataPackInf: TLabel
      Left = 108
      ExplicitLeft = 108
    end
    inherited lblStartTime: TLabel
      Left = 108
      ExplicitLeft = 108
    end
    inherited lblThreadInfo: TLabel
      Left = 108
      ExplicitLeft = 108
    end
    inherited lblWorkTimeLength: TLabel
      Left = 108
      Top = 28
      ExplicitLeft = 108
      ExplicitTop = 28
    end
  end
  object InIOCPServer1: TInIOCPServer
    HttpDataProvider = InHttpDataProvider1
    ServerAddr = 'localhost'
    ServerPort = 80
    StartParams.TimeOut = 0
    ThreadOptions.BusinessThreadCount = 4
    ThreadOptions.PushThreadCount = 4
    ThreadOptions.WorkThreadCount = 2
    AfterOpen = InIOCPServer1AfterOpen
    Left = 168
    Top = 240
  end
  object InHttpDataProvider1: TInHttpDataProvider
    KeepAlive = False
    OnAccept = InHttpDataProvider1Accept
    WebSocketManager = InWebSocketManager1
    Left = 232
    Top = 240
  end
  object InWebSocketManager1: TInWebSocketManager
    OnReceive = InWebSocketManager1Receive
    OnUpgrade = InWebSocketManager1Upgrade
    Left = 296
    Top = 240
  end
end
