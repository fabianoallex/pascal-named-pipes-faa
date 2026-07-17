object frmPdvCliente: TfrmPdvCliente
  Left = 720
  Top = 80
  Width = 480
  Height = 560
  Caption = 'PDV - Tela do Cliente (pascal-named-pipes-faa)'
  ClientHeight = 560
  ClientWidth = 480
  Color = clBtnFace
  Position = poScreenCenter
  OnDestroy = FormDestroy
  object lblPipe: TLabel
    Left = 8
    Top = 12
    Width = 26
    Height = 15
    Caption = 'Pipe:'
  end
  object lblStatus: TLabel
    Left = 8
    Top = 38
    Width = 84
    Height = 15
    Caption = 'desconectado'
  end
  object lblTotal: TLabel
    Left = 8
    Top = 260
    Width = 91
    Height = 15
    Caption = 'Total: R$ 0.00'
    Font.Style = [fsBold]
    ParentFont = False
  end
  object edtPipeName: TEdit
    Left = 44
    Top = 8
    Width = 160
    Height = 23
    TabOrder = 0
    Text = 'pipes_faa_pdv'
  end
  object btnConectar: TButton
    Left = 212
    Top = 7
    Width = 110
    Height = 25
    Caption = 'Conectar'
    TabOrder = 1
    OnClick = btnConectarClick
  end
  object listItens: TListBox
    Left = 8
    Top = 62
    Width = 464
    Height = 190
    Anchors = [akLeft, akTop, akRight]
    ItemHeight = 15
    TabOrder = 2
  end
  object pnlPagamento: TPanel
    Left = 8
    Top = 284
    Width = 464
    Height = 96
    BevelOuter = bvLowered
    TabOrder = 3
    Visible = False
    object lblEscolhaPagamento: TLabel
      Left = 8
      Top = 6
      Width = 156
      Height = 15
      Caption = 'Escolha a forma de pagamento:'
    end
    object btnDinheiro: TButton
      Left = 8
      Top = 30
      Width = 106
      Height = 50
      Caption = 'Dinheiro'
      TabOrder = 0
      OnClick = btnDinheiroClick
    end
    object btnDebito: TButton
      Left = 122
      Top = 30
      Width = 106
      Height = 50
      Caption = 'Debito'
      TabOrder = 1
      OnClick = btnDebitoClick
    end
    object btnCredito: TButton
      Left = 236
      Top = 30
      Width = 106
      Height = 50
      Caption = 'Credito'
      TabOrder = 2
      OnClick = btnCreditoClick
    end
    object btnPix: TButton
      Left = 350
      Top = 30
      Width = 106
      Height = 50
      Caption = 'Pix'
      TabOrder = 3
      OnClick = btnPixClick
    end
  end
  object memoLog: TMemo
    Left = 8
    Top = 388
    Width = 464
    Height = 164
    Anchors = [akLeft, akTop, akRight, akBottom]
    ReadOnly = True
    ScrollBars = ssVertical
    TabOrder = 4
  end
end
