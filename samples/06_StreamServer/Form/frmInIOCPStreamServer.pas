unit frmInIOCPStreamServer;

interface

uses
  Windows, Messages, SysUtils, Variants, Classes, Graphics, Controls, Forms,
  Dialogs, StdCtrls, iocp_sockets, iocp_server, fmIOCPSvrInfo;

type
  TFormInIOCPStreamServer = class(TForm)
    Memo1: TMemo;
    InIOCPServer1: TInIOCPServer;
    btnStart: TButton;
    btnStop: TButton;
    Edit1: TEdit;
    FrameIOCPSvrInfo1: TFrameIOCPSvrInfo;
    procedure FormCreate(Sender: TObject);
    procedure btnStartClick(Sender: TObject);
    procedure btnStopClick(Sender: TObject);
    procedure InIOCPServer1DataSend(Sender: TBaseSocket; Size: Cardinal);
    procedure InIOCPServer1DataReceive(Sender: TBaseSocket;
      const Data: PAnsiChar; Size: Cardinal);
    procedure InIOCPServer1AfterOpen(Sender: TObject);
    procedure InIOCPServer1AfterClose(Sender: TObject);
  private
    { Private declarations }
    FAppDir: String;
  public
    { Public declarations }
  end;

var
  FormInIOCPStreamServer: TFormInIOCPStreamServer;

implementation

uses
  iocp_log, iocp_utils, iocp_msgPacks, http_utils;
  
{$R *.dfm}

procedure TFormInIOCPStreamServer.btnStartClick(Sender: TObject);
begin
  Memo1.Lines.Clear;
  iocp_log.TLogThread.InitLog;              // 开启日志
  InIOCPServer1.ServerAddr := Edit1.Text;     // 地址
  InIOCPServer1.Active := True;               // 开启服务
  FrameIOCPSvrInfo1.Start(InIOCPServer1);     // 开始统计
end;

procedure TFormInIOCPStreamServer.btnStopClick(Sender: TObject);
begin
  InIOCPServer1.Active := False;   // 停止服务
  FrameIOCPSvrInfo1.Stop;          // 停止统计
  iocp_log.TLogThread.StopLog;   // 停止日志
end;

procedure TFormInIOCPStreamServer.FormCreate(Sender: TObject);
begin
  // 本地路径
//  Edit1.Text := GetLocalIp;
  FAppDir := ExtractFilePath(Application.ExeName);     
  MyCreateDir(FAppDir + 'log');
end;

procedure TFormInIOCPStreamServer.InIOCPServer1AfterClose(Sender: TObject);
begin
  btnStart.Enabled := not InIOCPServer1.Active;
  btnStop.Enabled := InIOCPServer1.Active;
end;

procedure TFormInIOCPStreamServer.InIOCPServer1AfterOpen(Sender: TObject);
begin
  btnStart.Enabled := not InIOCPServer1.Active;
  btnStop.Enabled := InIOCPServer1.Active;
  Memo1.Lines.Add('ip: ' + InIOCPServer1.ServerAddr);
  Memo1.Lines.Add('port: ' + IntToStr(InIOCPServer1.ServerPort));
end;

procedure TFormInIOCPStreamServer.InIOCPServer1DataReceive(Sender: TBaseSocket;
  const Data: PAnsiChar; Size: Cardinal);
//var
//  Stream: TFileStream;
begin
  // 收到一个数据包（未必接收完毕）
  // Sender: 是 TStreamSocket!
  //   Data: 数据
  //   Size：数据长度

  // 把数据转为 String 显示
  // SetString(S, Data, Size);
  // memo1.lines.Add(S);

  // 4 种方式发送数据

  // 1. 按原样发回数据
//  TStreamSocket(Sender).SendData(Data, Size);

  // 2. 发送文本
//  TStreamSocket(Sender).SendData('Test Text 中文');

  // 3. 发送一个 htm文件（含报头+内容）
{  Stream := TFileStream.Create('stream.htm', fmShareDenyWrite);  // 要共享读，否则很慢
  TStreamSocket(Sender).SendData(Stream);   // 自动释放 Stream  }

  // 4. 直接打开文件发送 Handle(共享读)
  TStreamSocket(Sender).SendData(InternalOpenFile('stream.htm'));

  // 5. 发送一个 Variant
//  TStreamSocket(Sender).SendDataVar(Value);  

end;

procedure TFormInIOCPStreamServer.InIOCPServer1DataSend(Sender: TBaseSocket;
  Size: Cardinal);
begin
  // 数据成功发出时执行此方法
  //   Sender: TStreamSocket! 不要操作 Sender
end;

end.
