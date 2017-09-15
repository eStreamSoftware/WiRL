object MainForm: TMainForm
  Left = 0
  Top = 0
  Caption = 'WiRL Filters Server'
  ClientHeight = 201
  ClientWidth = 464
  Color = clBtnFace
  Constraints.MinHeight = 240
  Constraints.MinWidth = 480
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -11
  Font.Name = 'Tahoma'
  Font.Style = []
  OldCreateOrder = False
  OnClose = FormClose
  OnCreate = FormCreate
  PixelsPerInch = 96
  TextHeight = 13
  object TopPanel: TPanel
    Left = 0
    Top = 0
    Width = 464
    Height = 73
    Align = alTop
    BevelOuter = bvNone
    TabOrder = 0
    object Label1: TLabel
      Left = 28
      Top = 17
      Width = 63
      Height = 13
      Caption = 'Port number:'
    end
    object StartButton: TButton
      Left = 16
      Top = 41
      Width = 75
      Height = 25
      Action = StartServerAction
      TabOrder = 0
    end
    object StopButton: TButton
      Left = 104
      Top = 41
      Width = 75
      Height = 25
      Action = StopServerAction
      TabOrder = 1
    end
    object PortNumberEdit: TEdit
      Left = 97
      Top = 14
      Width = 82
      Height = 21
      TabOrder = 2
      Text = '8080'
    end
  end
  object lstLog: TListBox
    Left = 0
    Top = 73
    Width = 464
    Height = 128
    Align = alClient
    ItemHeight = 13
    TabOrder = 1
  end
  object MainActionList: TActionList
    Left = 384
    Top = 24
    object StartServerAction: TAction
      Caption = 'Start Server'
      OnExecute = StartServerActionExecute
      OnUpdate = StartServerActionUpdate
    end
    object StopServerAction: TAction
      Caption = 'Stop Server'
      OnExecute = StopServerActionExecute
      OnUpdate = StopServerActionUpdate
    end
  end
  object WiRLServer1: TWiRLServer
    Active = False
    ThreadPoolSize = 5
    Left = 208
    Top = 112
  end
  object WiRLEngine1: TWiRLEngine
    BasePath = '/rest'
    EngineName = 'WiRL Filters'
    Server = WiRLServer1
    Left = 288
    Top = 120
    object WiRLApplication1: TWiRLApplication
      AppName = 'Filter Demo'
      BasePath = '/app'
      TokenLocation = Bearer
      Resource.List = (
        'Server.Resources.TFilterDemoResource')
      Filter.List = (
        '*')
    end
  end
end
