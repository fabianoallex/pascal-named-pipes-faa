object frmPdvOperador: TfrmPdvOperador
  Left = 120
  Top = 80
  Width = 560
  Height = 560
  Caption = 'PDV - Operador (pascal-named-pipes-faa)'
  ClientHeight = 560
  ClientWidth = 560
  Color = clBtnFace
  Position = poScreenCenter
  OnCreate = FormCreate
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
    Width = 55
    Height = 15
    Caption = 'fechado'
  end
  object lblDescricao: TLabel
    Left = 8
    Top = 68
    Width = 56
    Height = 15
    Caption = 'Descricao:'
  end
  object lblQuantidade: TLabel
    Left = 268
    Top = 68
    Width = 21
    Height = 15
    Caption = 'Qtd:'
  end
  object lblValor: TLabel
    Left = 340
    Top = 68
    Width = 51
    Height = 15
    Caption = 'Valor unit:'
  end
  object lblTotal: TLabel
    Left = 8
    Top = 300
    Width = 84
    Height = 15
    Caption = 'Total: R$ 0.00'
  end
  object lblFormaPagamento: TLabel
    Left = 8
    Top = 358
    Width = 3
    Height = 15
  end
  object edtPipeName: TEdit
    Left = 44
    Top = 8
    Width = 160
    Height = 23
    TabOrder = 0
    Text = 'pipes_faa_pdv'
  end
  object btnAbrirCaixa: TButton
    Left = 212
    Top = 7
    Width = 110
    Height = 25
    Caption = 'Abrir caixa'
    TabOrder = 1
    OnClick = btnAbrirCaixaClick
  end
  object edtDescricao: TEdit
    Left = 8
    Top = 86
    Width = 252
    Height = 23
    TabOrder = 2
  end
  object edtQuantidade: TEdit
    Left = 268
    Top = 86
    Width = 60
    Height = 23
    TabOrder = 3
    Text = '1'
  end
  object edtValor: TEdit
    Left = 340
    Top = 86
    Width = 80
    Height = 23
    TabOrder = 4
  end
  object btnAdicionarItem: TButton
    Left = 428
    Top = 84
    Width = 124
    Height = 25
    Caption = 'Adicionar item'
    Default = True
    TabOrder = 5
    OnClick = btnAdicionarItemClick
  end
  object listItens: TListBox
    Left = 8
    Top = 122
    Width = 544
    Height = 168
    Anchors = [akLeft, akTop, akRight]
    ItemHeight = 15
    TabOrder = 6
  end
  object btnSolicitarPagamento: TButton
    Left = 8
    Top = 326
    Width = 200
    Height = 25
    Caption = 'Solicitar forma de pagamento'
    Enabled = False
    TabOrder = 7
    OnClick = btnSolicitarPagamentoClick
  end
  object btnFinalizarVenda: TButton
    Left = 316
    Top = 326
    Width = 110
    Height = 25
    Caption = 'Finalizar venda'
    Enabled = False
    TabOrder = 8
    OnClick = btnFinalizarVendaClick
  end
  object btnCancelarVenda: TButton
    Left = 432
    Top = 326
    Width = 120
    Height = 25
    Caption = 'Cancelar venda'
    Enabled = False
    TabOrder = 9
    OnClick = btnCancelarVendaClick
  end
  object memoLog: TMemo
    Left = 8
    Top = 384
    Width = 544
    Height = 168
    Anchors = [akLeft, akTop, akRight, akBottom]
    ReadOnly = True
    ScrollBars = ssVertical
    TabOrder = 10
  end
end
