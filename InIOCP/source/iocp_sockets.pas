(*
 * iocp 服务端各种套接字封装
 *)
unit iocp_sockets;

interface

{$I in_iocp.inc}        // 模式设置

uses
  windows, Classes, SysUtils, Variants, DateUtils,
  iocp_base, iocp_zlib, iocp_api,
  iocp_Winsock2, iocp_wsExt, iocp_utils,
  iocp_baseObjs, iocp_objPools, iocp_senders,
  iocp_receivers, iocp_msgPacks, iocp_log,
  http_objects, iocp_WsJSON;

type

  // ================== 基本套接字 类 ======================

  TRawSocket = class(TObject)
  private
    FConnected: Boolean;       // 是否连接
    FErrorCode: Integer;       // 异常代码
    FPeerIP: String;           // IP
    FPeerIPPort: string;       // IP+Port
    FPeerPort: Integer;        // Port
    FSocket: TSocket;          // 套接字
    procedure InternalClose;    
  protected
    procedure SetSocket(const Value: TSocket); virtual;  
  public
    constructor Create(AddSocket: Boolean);
    destructor Destroy; override;
    procedure Close; virtual;
    procedure SetPeerAddr(const Addr: PSockAddrIn);
  public
    property Connected: Boolean read FConnected;
    property ErrorCode: Integer read FErrorCode;
    property PeerIP: String read FPeerIP;
    property PeerPort: Integer read FPeerPort;
    property PeerIPPort: String read FPeerIPPort;
    property Socket: TSocket read FSocket write SetSocket;
  public
    class function GetPeerIP(const Addr: PSockAddrIn): String;
  end;

  // ================== 监听套接字 类 ======================

  TListenSocket = class(TRawSocket)
  public
    function Bind(Port: Integer; const Addr: String = ''): Boolean;
    function StartListen: Boolean;
  end;

  // ================== AcceptEx 投放套接字 ======================

  TAcceptSocket = class(TRawSocket)
  private
    FListenSocket: TSocket;    // 监听套接字
    FIOData: TPerIOData;       // 内存块
    FByteCount: Cardinal;      // 投放用
  public
    constructor Create(ListenSocket: TSocket);
    destructor Destroy; override;
    function AcceptEx: Boolean; {$IFDEF USE_INLINE} inline; {$ENDIF}
    procedure NewSocket; {$IFDEF USE_INLINE} inline; {$ENDIF}
    function SetOption: Boolean; {$IFDEF USE_INLINE} inline; {$ENDIF}
  end;

  // ================== 业务执行模块基类 ======================

  TIOCPSocket = class;
  THttpSocket = class;
  TWebSocket  = class;

  TBaseWorker = class(TObject)
  protected
    FGlobalLock: TThreadLock;   // 全局锁
    FThreadIdx: Integer;        // 编号
  protected
    procedure Execute(const ASocket: TIOCPSocket); virtual; abstract;
    procedure HttpExecute(const ASocket: THttpSocket); virtual; abstract;
    procedure WSExecute(const ASocket: TWebSocket); virtual; abstract;
  public
    property GlobalLock: TThreadLock read FGlobalLock; // 可以在业务操时用
    property ThreadIdx: Integer read FThreadIdx;
  end;

  // ================== 服务端接收到的数据 ======================

  TReceiveParams = class(TReceivePack)
  private
    FMsgHead: PMsgHead;      // 协议头位置 
    FSocket: TIOCPSocket;    // 宿主
  public
    constructor Create(AOwner: TIOCPSocket);
    function GetData: Variant; override;
    function ToJSON: AnsiString; override;
    procedure CreateAttachment(const LocalPath: string); override;
  public
    property Socket: TIOCPSocket read FSocket;
    property AttachPath: string read GetAttachPath;
  end;

  // ================== 反馈给客户端的数据 ======================

  TReturnResult = class(TBaseMessage)
  private
    FSocket: TIOCPSocket;     // 宿主
    FSender: TBaseTaskSender; // 任务发送器
    procedure ReturnHead(AActResult: TActionResult = arOK);
    procedure ReturnResult;
  public
    constructor Create(AOwner: TIOCPSocket); reintroduce;
    procedure LoadFromFile(const AFileName: String; OpenAtOnce: Boolean = False); override;
    procedure LoadFromVariant(AData: Variant); override;
  public
    property ErrMsg: String read GetErrMsg write SetErrMsg;
    property Socket: TIOCPSocket read FSocket;
  public
    // 公开协议头属性
    property Action: TActionType read FAction;
    property ActResult: TActionResult read FActResult write FActResult;
    property AttachSize: TFileSize read FAttachSize;    
    property CheckType: TDataCheckType read FCheckType;
    property DataSize: Cardinal read FDataSize;
    property MsgId: TIOCPMsgId read FMsgId;
    property Offset: TFileSize read FOffset;
    property OffsetEnd: TFileSize read FOffsetEnd;
    property Owner: TMessageOwner read FOwner;
    property SessionId: Cardinal read FSessionId;
    property Target: TActionTarget read FTarget;
    property VarCount: Cardinal read FVarCount;
    property ZipLevel: TZipLevel read FZipLevel;
  end;

  // ================== Socket 基类 ======================
  // FState 状态：
  // 1. 空闲 = 0，关闭 = 9
  // 2. 占用 = 1，TransmitFile 时 +1，任何异常均 +1
  //    （正常值=1,2，其他值即为异常）
  // 3. 尝试关闭：空闲=0，TransmitFile=2（特殊的空闲），均可直接关闭
  // 4. 加锁：空闲=0 -> 成功

  TBaseSocket = class(TRawSocket)
  private
    FLinkNode: PLinkRec;       // 对应客户端池的 PLinkRec，方便回收
    FPool: TIOCPSocketPool;    // 所属池（可移至TLinkRec）

    FRecvBuf: PPerIOData;      // 接收用的数据包
    FSender: TBaseTaskSender;  // 数据发送器（引用）
    FWorker: TBaseWorker;      // 业务执行者（引用）

    FByteCount: Cardinal;      // 接收字节数
    FComplete: Boolean;        // 接收完毕/触发业务

    FRefCount: Integer;        // 引用数
    FState: Integer;           // 状态（原子操作变量）
    FTickCount: Cardinal;      // 客户端访问毫秒数
    FUseTransObj: Boolean;     // 使用 TTransmitObject 发送
    
    function CheckDelayed(ATickCount: Cardinal): Boolean;
    function GetActive: Boolean;
    function GetReference: Boolean;
    function GetSocketState: Boolean;

    procedure InterCloseSocket(Sender: TObject); 
    procedure InternalRecv(Complete: Boolean);
    procedure OnSendError(Sender: TObject);
  protected
    {$IFDEF TRANSMIT_FILE}      // TransmitFile 发送模式
    FTask: TTransmitObject;     // 待发送数据描述
    FTaskExists: Boolean;       // 存在任务
    procedure InterTransmit;    // 发送数据
    procedure InterFreeRes; virtual; abstract; // 释放发送资源
    {$ENDIF}
    procedure ClearResources; virtual; abstract;
    procedure ExecuteWork; virtual; abstract;  // 调用入口
    procedure InternalPush(AData: PPerIOData); // 推送入口
    procedure SetSocket(const Value: TSocket); override;
    procedure SocketError(IOKind: TIODataType); virtual;
  public
    constructor Create(APool: TIOCPSocketPool; ALinkNode: PLinkRec); virtual;
    destructor Destroy; override;

    // 超时检查
    function CheckTimeOut(ANowTickCount: Cardinal): Boolean;

    // 克隆（转移资源）
    procedure Clone(Source: TBaseSocket);

    // 关闭
    procedure Close; override;

    // 业务线程调用入口
    procedure DoWork(AWorker: TBaseWorker; ASender: TBaseTaskSender);

    {$IFDEF TRANSMIT_FILE}
    procedure FreeTransmitRes;  // 释放 TransmitFile 的资源
    {$ENDIF}
    
    // 工作前加锁
    function Lock(PushMode: Boolean): Integer; virtual;

    // 投递接收
    procedure PostRecv; virtual;

    // 投放事件：被删除、拒绝服务、超时
    procedure PostEvent(IOKind: TIODataType); virtual; abstract;

    // 尝试关闭
    procedure TryClose;

    // 设置单元变量
    class procedure SetUnitVariables(Server: TObject);
  public
    property Active: Boolean read GetActive;
    property Complete: Boolean read FComplete;
    property LinkNode: PLinkRec read FLinkNode;
    property Pool: TIOCPSocketPool read FPool;
    property RecvBuf: PPerIOData read FRecvBuf;
    property Reference: Boolean read GetReference;
    property Sender: TBaseTaskSender read FSender;
    property SocketState: Boolean read GetSocketState;
    property Worker: TBaseWorker read FWorker;
  end;

  TBaseSocketClass = class of TBaseSocket;

  // ================== TStreamSocket 原始数据流 ==================

  TStreamSocket = class(TBaseSocket)
  protected
    {$IFDEF TRANSMIT_FILE}
    procedure InterFreeRes; override;
    {$ENDIF}
    procedure ClearResources; override;
    procedure ExecuteWork; override;
  public
    procedure PostEvent(IOKind: TIODataType); override;
    procedure SendData(const Data: PAnsiChar; Size: Cardinal); overload; virtual;
    procedure SendData(const Msg: String); overload; virtual;
    procedure SendData(Handle: THandle); overload; virtual;
    procedure SendData(Stream: TStream); overload; virtual;
    procedure SendDataVar(Data: Variant); virtual; 
  end;

  // ================== 服务端 WebSocket 类 ==================

  TResultJSON = class(TSendJSON)
  public
    property DataSet;
  end;
  
  TWebSocket = class(TStreamSocket)
  protected
    FReceiver: TWSServerReceiver;  // 数据接收器
    FJSON: TBaseJSON;          // 收到的 JSON 数据
    FResult: TResultJSON;      // 要返回的 JSON 数据
        
    FData: PAnsiChar;          // 本次收到的数据引用位置
    FMsgSize: UInt64;          // 当前消息收到的累计长度
    FFrameSize: UInt64;        // 当前帧长度
    FFrameRecvSize: UInt64;    // 本次收到的数据长度

    FMsgType: TWSMsgType;      // 数据类型
    FOpCode: TWSOpCode;        // WebSocket 操作类型
    FRole: TClientRole;        // 客户权限（预设）
    FUserName: TNameString;    // 用户名称（预设）

    procedure ClearMsgOwner(Buf: PAnsiChar; Len: Integer);
    procedure InternalPing;    
  protected
    procedure ClearResources; override;
    procedure ExecuteWork; override;
    procedure InterPush(Target: TWebSocket = nil);
    procedure SetProps(AOpCode: TWSOpCode; AMsgType: TWSMsgType;
                       AData: Pointer; AFrameSize: Int64; ARecvSize: Cardinal);
  public
    constructor Create(APool: TIOCPSocketPool; ALinkNode: PLinkRec); override;
    destructor Destroy; override;

    procedure PostEvent(IOKind: TIODataType); override;
    procedure SendData(const Data: PAnsiChar; Size: Cardinal); overload; override;
    procedure SendData(const Msg: String); overload; override;
    procedure SendData(Handle: THandle); overload; override;
    procedure SendData(Stream: TStream); overload; override;
    procedure SendDataVar(Data: Variant); override;

    procedure SendResult(UTF8CharSet: Boolean = False);
  public
    property Data: PAnsiChar read FData;  // raw
    property FrameRecvSize: UInt64 read FFrameRecvSize; // raw
    property FrameSize: UInt64 read FFrameSize; // raw
    property MsgSize: UInt64 read FMsgSize; // raw

    property JSON: TBaseJSON read FJSON; // JSON
    property Result: TResultJSON read FResult; // JSON
  public
    property MsgType: TWSMsgType read FMsgType; // 数据类型
    property OpCode: TWSOpCode read FOpCode;  // WebSocket 操作
  public
    property Role: TClientRole read FRole write FRole;
    property UserName: TNameString read FUserName write FUserName;
  end;

  // ================== C/S 模式业务处理 ==================

  TIOCPSocket = class(TBaseSocket)
  private
    FReceiver: TServerReceiver;// 数据接收器
    FParams: TReceiveParams;   // 接收到的消息（变量化）
    FResult: TReturnResult;    // 返回的数据
    FData: PEnvironmentVar;    // 工作环境信息
    FAction: TActionType;      // 内部事件
    FSessionId: Cardinal;      // 对话凭证 id
    function CreateSession: Cardinal;
    function SessionValid(ASession: Cardinal): Boolean;
    procedure SetLogoutState;
  protected
    {$IFDEF TRANSMIT_FILE}
    procedure InterFreeRes; override;
    {$ENDIF}  
    function CheckMsgHead(InBuf: PAnsiChar): Boolean;
    procedure ClearResources; override;
    procedure CreateResources; 
    procedure ExecuteWork; override;  // 调用入口
    procedure HandleDataPack; 
    procedure ReturnMessage(ActResult: TActionResult; const ErrMsg: String = ''); 
    procedure SetSocket(const Value: TSocket); override;
    procedure SocketError(IOKind: TIODataType); override;
  public
    destructor Destroy; override;
  public
    // 业务模块调用
    procedure Push(Target: TIOCPSocket = nil);
    procedure PostEvent(IOKind: TIODataType); override;
    procedure SetLogState(AData: PEnvironmentVar);
    procedure SetUniqueMsgId;
  public
    property Action: TActionType read FAction;
    property Data: PEnvironmentVar read FData;
    property Params: TReceiveParams read FParams;
    property Result: TReturnResult read FResult;
    property SessionId: Cardinal read FSessionId;
  end;

  // ================== Socket Http 处理 ==================

  TRequestObject = class(THttpRequest);
  TResponeObject = class(THttpRespone);

  THttpSocket = class(TBaseSocket)
  private
    FRequest: THttpRequest;    // http 请求
    FRespone: THttpRespone;    // http 应答
    FStream: TFileStream;      // 接收文件的流
    FKeepAlive: Boolean;       // 保持连接
    FSessionId: AnsiString;    // Session Id
    procedure UpgradeSocket(SocketPool: TIOCPSocketPool);
    procedure DecodeHttpRequest;
  protected
    {$IFDEF TRANSMIT_FILE}
    procedure InterFreeRes; override;
    {$ENDIF}
    procedure ClearResources; override;
    procedure ExecuteWork; override;
    procedure SocketError(IOKind: TIODataType); override;
  public
    destructor Destroy; override;
    // 推送事件
    procedure PostEvent(IOKind: TIODataType); override;
    // 文件流操作
    procedure CreateStream(const FileName: String);
    procedure WriteStream(Data: PAnsiChar; DataLength: Integer);
    procedure CloseStream;
  public
    property Request: THttpRequest read FRequest;
    property Respone: THttpRespone read FRespone;
    property SessionId: AnsiString read FSessionId;
  end;

  // ================== TSocketBroker 代理套接字 ==================

  TSocketBroker = class;

  TBindIPEvent  = procedure(Sender: TSocketBroker; const Data: PAnsiChar;
                            DataSize: Cardinal) of object;
  TOuterPingEvent  = TBindIPEvent;

  TSocketBroker = class(TBaseSocket)
  private
    FDual: TSocketBroker;      // 关联的中继
    FAction: Integer;          // 初始化

    FContentLength: Integer;   // Http 实体总长
    FReceiveSize: Integer;     // Http 收到的实体长度
    FSocketType: TSocketBrokerType;  // 类型

    FTargetHost: AnsiString;   // 关联的主机地址
    FTargetPort: Integer;      // 关联的服务器端口
    FToSocket: TSocket;        // 关联的目的套接字

    FOnBind: TBindIPEvent;     // 绑定事件

    function CheckInnerSocket: Boolean;
    function ChangeConnection(const ABrokerId, AServer: AnsiString; APort: Integer): Boolean;

    procedure ExecSocketAction;
    procedure ForwardData;

    // HTTP 协议
    procedure HttpBindOuter(Connection: TSocketBroker; const Data: PAnsiChar; DataSize: Cardinal);
    procedure HttpConnectHost(const AServer: AnsiString; APort: Integer);  // 连接到 HTTP 的 Host
    procedure HttpRequestDecode;  // Http 请求的简单解码
  protected
    FBrokerId: AnsiString;     // 所属的反向代理 Id
    procedure ClearResources; override;
    procedure ExecuteWork; override;
  protected
    procedure AssociateInner(InnerBroker: TSocketBroker);
    procedure SendInnerFlag;
    procedure SetConnection(Connection: TSocket);
    procedure SetSocket(const Value: TSocket); override;
  public
    function  Lock(PushMode: Boolean): Integer; override;
    procedure CreateBroker(const AServer: AnsiString; APort: Integer);  // 建连接中继
    procedure PostEvent(IOKind: TIODataType); override;
  end;

implementation

uses
  iocp_server, http_base, http_utils, iocp_threads, iocp_managers;

type
  THeadMessage   = class(TBaseMessage);
  TInIOCPBrokerX = class(TInIOCPBroker);

var
      FServer: TInIOCPServer = nil;   // 单元服务器变量
  FGlobalLock: TThreadLock = nil;     // 全局锁
 FPushManager: TPushMsgManager = nil; // 消息推送管理
  FIOCPBroker: TInIOCPBroker = nil;   // 代理服务
 FServerMsgId: TIOCPMsgId = 0;        // 唯一推送消息号

{ TRawSocket }

procedure TRawSocket.Close;
begin
  if FConnected then
    InternalClose;  // 关闭
end;

constructor TRawSocket.Create(AddSocket: Boolean);
begin
  inherited Create;
  if AddSocket then  // 建一个 Socket
    SetSocket(iocp_utils.CreateSocket);
end;

destructor TRawSocket.Destroy;
begin
  if FConnected then
    InternalClose; // 关闭
  inherited;
end;

class function TRawSocket.GetPeerIP(const Addr: PSockAddrIn): String;
begin
  // 取IP
  Result := iocp_Winsock2.inet_ntoa(Addr^.sin_addr);
end;

procedure TRawSocket.InternalClose;
begin
  // 关闭 Socket
  try
    iocp_Winsock2.Shutdown(FSocket, SD_BOTH);
    iocp_Winsock2.CloseSocket(FSocket);
    FSocket := INVALID_SOCKET;
  finally
    FConnected := False;        
  end;
end;

procedure TRawSocket.SetPeerAddr(const Addr: PSockAddrIn);
begin
  // 从地址信息取 IP、Port
  FPeerIP := iocp_Winsock2.inet_ntoa(Addr^.sin_addr);
  FPeerPort := Addr^.sin_port;
  FPeerIPPort := FPeerIP + ':' + IntToStr(FPeerPort);
end;

procedure TRawSocket.SetSocket(const Value: TSocket);
begin
  // 设置 Socket
  FSocket := Value;
  FConnected := FSocket <> INVALID_SOCKET;
end;

{ TListenSocket }

function TListenSocket.Bind(Port: Integer; const Addr: String): Boolean;
var
  SockAddr: TSockAddrIn;
begin
  // 绑定地址
  // htonl(INADDR_ANY); 在任何地址（多块网卡）上监听
  FillChar(SockAddr, SizeOf(TSockAddr), 0);

  SockAddr.sin_family := AF_INET;
  SockAddr.sin_port := htons(Port);
  SockAddr.sin_addr.S_addr := inet_addr(PAnsiChar(ResolveHostIP(Addr)));

  if (iocp_Winsock2.bind(FSocket, TSockAddr(SockAddr), SizeOf(TSockAddr)) <> 0) then
  begin
    Result := False;
    FErrorCode := WSAGetLastError;
    iocp_log.WriteLog('TListenSocket.Bind->Error:' + IntToStr(FErrorCode));
  end else
  begin
    Result := True;
    FErrorCode := 0;
  end;
end;

function TListenSocket.StartListen: Boolean;
begin
  // 监听
  if (iocp_Winsock2.listen(FSocket, MaxInt) <> 0) then
  begin
    Result := False;
    FErrorCode := WSAGetLastError;
    iocp_log.WriteLog('TListenSocket.StartListen->Error:' + IntToStr(FErrorCode));
  end else
  begin
    Result := True;
    FErrorCode := 0;
  end;
end;

{ TAcceptSocket }

function TAcceptSocket.AcceptEx: Boolean;
begin
  // 投放 AcceptEx 请求
  FillChar(FIOData.Overlapped, SizeOf(TOverlapped), 0);

  FIOData.Owner := Self;       // 宿主
  FIOData.IOType := ioAccept;  // 再设置
  FByteCount := 0;

  Result := gAcceptEx(FListenSocket, FSocket,
                      Pointer(FIOData.Data.buf), 0,   // 用 0，不等待第一包数据
                      ADDRESS_SIZE_16, ADDRESS_SIZE_16,
                      FByteCount, @FIOData.Overlapped);

  if Result then
    FErrorCode := 0
  else begin
    FErrorCode := WSAGetLastError;
    Result := FErrorCode = WSA_IO_PENDING;
    if (Result = False) then
      iocp_log.WriteLog('TAcceptSocket.AcceptEx->Error:' + IntToStr(FErrorCode));
  end;
end;

constructor TAcceptSocket.Create(ListenSocket: TSocket);
begin
  inherited Create(True);
  // 新建 AcceptEx 用的 Socket
  FListenSocket := ListenSocket;
  GetMem(FIOData.Data.buf, ADDRESS_SIZE_16 * 2);  // 申请一块内存
  FIOData.Data.len := ADDRESS_SIZE_16 * 2;
  FIOData.Node := nil;  // 无
end;

destructor TAcceptSocket.Destroy;
begin
  FreeMem(FIOData.Data.buf);  // 释放内存块
  inherited;
end;

procedure TAcceptSocket.NewSocket;
begin
  // 新建 Socket
  FSocket := iocp_utils.CreateSocket;
end;

function TAcceptSocket.SetOption: Boolean;
begin
  // 复制 FListenSocket 的属性到 FSocket
  Result := iocp_Winsock2.setsockopt(FSocket, SOL_SOCKET,
                 SO_UPDATE_ACCEPT_CONTEXT, PAnsiChar(@FListenSocket),
                 SizeOf(TSocket)) <> SOCKET_ERROR;
end;

{ TReceiveParams }

constructor TReceiveParams.Create(AOwner: TIOCPSocket);
begin
  inherited Create;
  FSocket := AOwner;
end;

procedure TReceiveParams.CreateAttachment(const LocalPath: string);
begin
  inherited;      
  // 建流，接收附件
  if Error then  // 出现错误
    FSocket.FResult.ActResult := arFail
  else begin
    FSocket.FAction := atAfterReceive; // 结束时执行事件
    FSocket.FResult.FActResult := arAccept;  // 允许上传

    // 续传
    if (FAction in FILE_CHUNK_ACTIONS) then
    begin
      // 加密路径，返回给客户端
      FSocket.FResult.SetAttachPath(iocp_utils.EncryptString(LocalPath));

      // 原样返回客户端的 路径+文件名...
      FSocket.FResult.SetFileSize(GetFileSize);
      FSocket.FResult.SetDirectory(Directory);
      FSocket.FResult.SetFileName(FileName);
      FSocket.FResult.SetNewCreatedFile(GetNewCreatedFile);
    end;

    FSocket.FReceiver.Complete := False;  // 恢复，接收附件
  end;
end;

function TReceiveParams.GetData: Variant;
begin
  Result := inherited GetData;
end;

function TReceiveParams.ToJSON: AnsiString;
begin
  Result := inherited ToJSON;
end;

{ TReturnResult }

constructor TReturnResult.Create(AOwner: TIOCPSocket);
begin
  inherited Create(nil);  // 用接收的 Owner
  FSocket := AOwner;
end;

procedure TReturnResult.LoadFromFile(const AFileName: String; OpenAtOnce: Boolean);
begin
  // 立刻打开文件，等待发送
  if (FileExists(AFileName) = False) then
  begin
    FActResult := arMissing;
    FOffset := 0;
    FOffsetEnd := 0;
  end else
  begin
    inherited;
    if (FAction = atFileDownChunk) then  // 断点下载
    begin
      // FParams.FOffsetEnd 转义, 是期望长度, == 客户端 FMaxChunkSize
      FOffset := FSocket.FParams.FOffset;  // 请求位移
      AdjustTransmitRange(FSocket.FParams.FOffsetEnd);
      // 返回客户端文件名，本地路径（加密）给客户端
      SetFileName(FSocket.FParams.FileName);
      SetAttachPath(iocp_utils.EncryptString(ExtractFilePath(AFileName)));
    end;
    if Error then
      FActResult := arFail
    else
      FActResult := arOK;
  end;
end;

procedure TReturnResult.LoadFromVariant(AData: Variant);
begin
  inherited;  // 直接调用
end;

procedure TReturnResult.ReturnHead(AActResult: TActionResult);
begin
  // 反馈协议头给客户端（响应、其他消息）
  //   格式：IOCP_HEAD_FLAG + TMsgHead

  // 更新协议头信息
  FDataSize := 0;
  FAttachSize := 0;
  FActResult := AActResult;

  if (FAction = atUnknown) then  // 响应
    FVarCount := FServer.IOCPSocketPool.UsedCount // 客户端要判断
  else
    FVarCount := 0;

  // 直接写入 FSender 的发送缓存
  LoadHead(FSender.Data);

  // 发送（长度 = ByteCount）
  FSender.SendBuffers;
end;

procedure TReturnResult.ReturnResult;
  procedure SendMsgHeader;
  begin
    // 发送协议头（描述）
    LoadHead(FSender.Data);
    FSender.SendBuffers;
  end;
  procedure SendMainStream;
  begin
    // 发送主体数据流
    {$IFDEF TRANSMIT_FILE}
    // 设置主体数据流
    FSocket.FTask.SetTask(FMain, FDataSize);
    {$ELSE}
    FSender.Send(FMain, FDataSize, False);  // 不关闭资源
    {$ENDIF}
  end;
  procedure SendAttachmentStream;
  begin
    // 发送附件数据
    {$IFDEF TRANSMIT_FILE}
    // 设置附件数据流
    if (FAction = atFileDownChunk) then
      FSocket.FTask.SetTask(FAttachment, FAttachSize, FOffset, FOffsetEnd)
    else
      FSocket.FTask.SetTask(FAttachment, FAttachSize);
    {$ELSE}
    // 不关闭资源
    if (FAction = atFileDownChunk) then
      FSender.Send(FAttachment, FAttachSize, FOffset, FOffsetEnd, False)
    else
      FSender.Send(FAttachment, FAttachSize, False);
    {$ENDIF}
  end;
begin
  // 发送结果给客户端，不用请求，直接发送
  //  附件流是 TIOCPDocument，还要用，不能释放
  //   见：TIOCPSocket.HandleDataPack; TClientParams.InternalSend

  // FSender.Socket、Owner 已经设置

  try
    // 1. 准备数据流
    CreateStreams;

    if (Error = False) then
    begin
      // 2. 发协议头
      SendMsgHeader;

      // 3. 主体数据（内存流）
      if (FDataSize > 0) then
        SendMainStream;

      // 4. 发送附件数据
      if (FAttachSize > 0) then
        SendAttachmentStream;
    end;
  finally
    {$IFDEF TRANSMIT_FILE}
    FSocket.InterTransmit;
    {$ELSE}
    NilStreams(False);  // 5. 清空，暂不释放附件流
    {$ENDIF}
  end;

end;

{ TBaseSocket }

constructor TBaseSocket.Create(APool: TIOCPSocketPool; ALinkNode: PLinkRec);
begin
  inherited Create(False);
  // FSocket 由客户端接入时分配
  //   见：TInIOCPServer.AcceptClient
  //       TIOCPSocketPool.CreateObjData
  FPool := APool;
  FLinkNode := ALinkNode;
  FUseTransObj := True;  
end;

function TBaseSocket.CheckDelayed(ATickCount: Cardinal): Boolean;
begin
  // 取距最近活动时间的差
  if (ATickCount >= FTickCount) then
    Result := ATickCount - FTickCount <= 3000
  else
    Result := High(Cardinal) - ATickCount + FTickCount <= 3000;
  {$IFDEF TRANSMIT_FILE}
  if Assigned(FTask) then  // TransmitFile 没有任务
    Result := Result and (FTask.Exists = False);
  {$ENDIF}
end;

function TBaseSocket.CheckTimeOut(ANowTickCount: Cardinal): Boolean;
  function GetTickCountDiff: Boolean;
  begin
    if (ANowTickCount >= FTickCount) then
      Result := ANowTickCount - FTickCount >= FServer.TimeOut
    else
      Result := High(Cardinal) - FTickCount + ANowTickCount >= FServer.TimeOut;
  end;
begin
  // 超时检查
  if (FTickCount = NEW_TICKCOUNT) then  // 投放即断开，见：TBaseSocket.SetSocket
  begin
    Inc(FByteCount);  // ByteCount +
    Result := (FByteCount >= 5);  // 连续几次
  end else
    Result := GetTickCountDiff;
end;

procedure TBaseSocket.Clone(Source: TBaseSocket);
begin
  // 对象变换：把 Source 的套接字等资源转移到新对象
  // 由 TIOCPSocketPool 加锁调用，防止被检查为超时

  // 转移 Source 的套接字、地址
  SetSocket(Source.FSocket);

  FPeerIP := Source.FPeerIP;
  FPeerPort := Source.FPeerPort;
  FPeerIPPort := Source.FPeerIPPort;

  // 标注 Source 的资源无效
  Source.FSocket := INVALID_SOCKET;
  Source.FConnected := False;

  // 未建 FTask  
end;

procedure TBaseSocket.Close;
begin
  ClearResources;  // 只清空资源，不释放，下次不用新建
  inherited;
end;

destructor TBaseSocket.Destroy;
begin
  // 释放时才回收（见：TryClose）
  {$IFDEF TRANSMIT_FILE}
  if Assigned(FTask) then
    FTask.Free;
  {$ENDIF}
  if Assigned(FServer) then
    if FServer.Active and Assigned(FRecvBuf) then
    begin
      FServer.IODataPool.Push(FRecvBuf^.Node);
      FRecvBuf := Nil;
    end;
  inherited;
end;

procedure TBaseSocket.DoWork(AWorker: TBaseWorker; ASender: TBaseTaskSender);
begin
  // 初始化
  // 任务结束后不设 FWorker、FSender 为 Nil

  {$IFDEF TRANSMIT_FILE}
  if FUseTransObj then
  begin
    if (Assigned(FTask) = False) then
    begin
      FTask := TTransmitObject.Create(Self); // TransmitFile 对象
      FTask.OnError := OnSendError;
    end;
    FTask.Socket := FSocket;
    FTaskExists := False; // 必须
  end;
  {$ENDIF}
  
  FErrorCode := 0;      // 无异常
  FByteCount := FRecvBuf^.Overlapped.InternalHigh;  // 收到字节数

  FWorker := AWorker;   // 执行者
  FSender := ASender;   // 发送器

  FSender.Owner := Self;
  FSender.Socket := FSocket;
  FSender.OnError := OnSendError;

  // 执行任务
  ExecuteWork;
    
end;

{$IFDEF TRANSMIT_FILE}
procedure TBaseSocket.FreeTransmitRes;
begin
  // 工作线程调用：TransmitFile 发送完毕
  if (windows.InterlockedDecrement(FState) = 1) then  // FState=2 -> 正常，否则异常
    InterFreeRes // 在子类实现，正式释放发送资源，判断是否继续投放 WSARecv！
  else
    InterCloseSocket(Self);
end;
{$ENDIF}

function TBaseSocket.GetActive: Boolean;
begin
  // 推送前取初始化状态（接收过数据）
  Result := (iocp_api.InterlockedCompareExchange(Integer(FByteCount), 0, 0) > 0);
end;

function TBaseSocket.GetReference: Boolean;
begin
  // 推送时引用（业务引用 FRecvBuf^.RefCount）
  Result := windows.InterlockedIncrement(FRefCount) = 1;
end;

function TBaseSocket.GetSocketState: Boolean;
begin
  // 取状态, FState = 1 说明正常
  Result := iocp_api.InterlockedCompareExchange(FState, 1, 1) = 1;
end;

procedure TBaseSocket.InternalPush(AData: PPerIOData);
var
  ByteCount, Flags: Cardinal;
begin
  // 推送消息（推送线程调用）
  //  AData：TPushMessage.FPushBuf

  // 清重叠结构
  FillChar(AData^.Overlapped, SizeOf(TOverlapped), 0);

  FErrorCode := 0;
  FRefCount := 0;  // AData:Socket = 1:n
  FTickCount := GetTickCount;  // +

  ByteCount := 0;
  Flags := 0;

  if (Windows.InterlockedDecrement(FState) <> 0) then
    InterCloseSocket(Self)
  else
    if (iocp_Winsock2.WSASend(FSocket, @(AData^.Data), 1, ByteCount,
        Flags, LPWSAOVERLAPPED(@AData^.Overlapped), nil) = SOCKET_ERROR) then
    begin
      FErrorCode := WSAGetLastError;
      if (FErrorCode <> ERROR_IO_PENDING) then  // 异常
      begin
        SocketError(AData^.IOType);
        InterCloseSocket(Self);  // 关闭
      end else
        FErrorCode := 0;
    end;

end;

procedure TBaseSocket.InternalRecv(Complete: Boolean);
var
  ByteCount, Flags: DWORD;
begin
  // 在任务结束最后提交一个接收请求

  // 未接收完成，缩短超时时间（防恶意攻击）
  if (Complete = False) and (FServer.TimeOut > 0) then
    Dec(FTickCount, 10000);

  // 清重叠结构
  FillChar(FRecvBuf^.Overlapped, SizeOf(TOverlapped), 0);

  FRecvBuf^.Owner := Self;  // 宿主
  FRecvBuf^.IOType := ioReceive;  // iocp_server 中判断用
  FRecvBuf^.Data.len := IO_BUFFER_SIZE; // 恢复
  FRecvBuf^.RefCount := 0;  // 清引用，可以改为 FRefCount

  ByteCount := 0;
  Flags := 0;

  // 正常时 FState=1，其他任何值都说明出现了异常，
  // FState-，FState <> 0 -> 异常改变了状态，关闭！

  if (Windows.InterlockedDecrement(FState) <> 0) then
    InterCloseSocket(Self)
  else  // FRecvBuf^.Overlapped 与 TPerIOData 同地址
    if (iocp_Winsock2.WSARecv(FSocket, @(FRecvBuf^.Data), 1, ByteCount,
        Flags, LPWSAOVERLAPPED(@FRecvBuf^.Overlapped), nil) = SOCKET_ERROR) then
    begin
      FErrorCode := WSAGetLastError;
      if (FErrorCode <> ERROR_IO_PENDING) then  // 异常
      begin
        SocketError(ioReceive);
        InterCloseSocket(Self);  // 关闭
      end else
        FErrorCode := 0;
    end;

  // 投放完成，设 FByteCount > 0, 可以接受推送消息了, 同时注意超时检查
  //   见：CheckTimeOut、TPushThread.DoMethod、TIOCPSocketPool.GetSockets
  if (FByteCount = 0) then
    FByteCount := 1;  // 不能太大，否则超时

  // 任务完成  
  if (FComplete <> Complete) then
    FComplete := Complete;
    
end;

function TBaseSocket.Lock(PushMode: Boolean): Integer;
const
  SOCKET_STATE_IDLE  = 0;  // 空闲
  SOCKET_STATE_BUSY  = 1;  // 在用
  SOCKET_STATE_TRANS = 2;  // TransmitFile 在用 
begin
  // 工作前加锁
  //  状态 FState = 0 -> 1, 且上次任务完成 -> 成功！
  //  以后在 Socket 内部的任何异常都 FState+
  case iocp_api.InterlockedCompareExchange(FState, 1, 0) of  // 返回原值

    SOCKET_STATE_IDLE: begin
      if PushMode then   // 推送模式
      begin
        if FComplete then
          Result := SOCKET_LOCK_OK
        else
          Result := SOCKET_LOCK_FAIL;
      end else
      begin
        // 业务线程模式，见：TWorkThread.HandleIOData
        Result := SOCKET_LOCK_OK;  // 总是运行
      end;
      if (Result = SOCKET_LOCK_FAIL) then // 业务未完成，放弃！
        if (windows.InterlockedDecrement(FState) <> 0) then
          InterCloseSocket(Self);
    end;

    SOCKET_STATE_BUSY,
    SOCKET_STATE_TRANS:
      Result := SOCKET_LOCK_FAIL;  // 在用

    else
      Result := SOCKET_LOCK_CLOSE; // 已关闭或工作中异常
  end;
end;

procedure TBaseSocket.InterCloseSocket(Sender: TObject);
begin
  // 内部关闭
  windows.InterlockedExchange(Integer(FByteCount), 0); // 不接受推送了
  windows.InterlockedExchange(FState, 9);  // 无效状态
  FServer.CloseSocket(Self);  // 用关闭线程（允许重复关闭）
end;

{$IFDEF TRANSMIT_FILE}
procedure TBaseSocket.InterTransmit;
begin
  if FTask.Exists then
  begin
    FTaskExists := True;
    windows.InterlockedIncrement(FState);  // FState+，正常时=2
    FTask.TransmitFile;
  end;
end;
{$ENDIF}

procedure TBaseSocket.OnSendError(Sender: TObject);
begin
  // 任务发送异常的回调方法
  //   见：TBaseSocket.DoWork、TBaseTaskObject.Send...
  FErrorCode := TBaseTaskObject(Sender).ErrorCode;
  Windows.InterlockedIncrement(FState);  // FState+
  SocketError(TBaseTaskObject(Sender).IOType);
end;

procedure TBaseSocket.PostRecv;
begin
  // 接入时投放接收缓存
  //   见：TInIOCPServer.AcceptClient、THttpSocket.ExecuteWork
  FState := 1;  // 设繁忙
  InternalRecv(True); // 投放时 FState-
end;

class procedure TBaseSocket.SetUnitVariables(Server: TObject);
begin
  // 设置单元服务器变量
  FServer := TInIOCPServer(Server);
  if Assigned(Server) then
  begin
    FIOCPBroker := FServer.IOCPBroker;
    FGlobalLock := FServer.GlobalLock;
    FPushManager := FServer.PushManager;
  end else
  begin
    FIOCPBroker := nil;
    FGlobalLock := nil;
    FPushManager := nil;
  end;
end;

procedure TBaseSocket.SetSocket(const Value: TSocket);
begin
  inherited;
  // 分配接收内存块（关闭时不回收，见 TryClose）
  if (FRecvBuf = nil) then
  begin
    FRecvBuf := FServer.IODataPool.Pop^.Data;
    FRecvBuf^.IOType := ioReceive;  // 类型
    FRecvBuf^.Owner := Self;  // 宿主
  end;

  FByteCount := 0;   // 接收数据长度
  FComplete := True; // 等待接收
  FErrorCode := 0;   // 无异常
  FState := 9;       // 无效状态，投放 Recv 才算正式使用

  // 最大值，防止被监测为超时，
  //   见：TTimeoutThread.ExecuteWork
  FTickCount := NEW_TICKCOUNT;

end;

procedure TBaseSocket.SocketError(IOKind: TIODataType);
const
  PROCEDURE_NAMES: array[ioReceive..ioTimeOut] of string = (
                   'Post WSARecv->', 'Post WSASend->',
                   {$IFDEF TRANSMIT_FILE} 'TransmitFile->', {$ENDIF}
                   'InternalPush->', 'InternalPush->',
                   'InternalPush->');
begin
  // 写异常日志
  if Assigned(FWorker) then  // 主动型代理投放，没有 FWorker
    iocp_log.WriteLog(PROCEDURE_NAMES[IOKind] + PeerIPPort +
                      ',Error:' + IntToStr(FErrorCode) +
                      ',BusiThread:' + IntToStr(FWorker.ThreadIdx));
end;

procedure TBaseSocket.TryClose;
begin
  // 尝试关闭
  // FState+, 原值: 0,2,3... <> 1 -> 关闭
  if (windows.InterlockedIncrement(FState) in [1, 3]) then // <> 2
    InterCloseSocket(Self);
end;

{ TStreamSocket }

procedure TStreamSocket.ClearResources;
begin
  {$IFDEF TRANSMIT_FILE}
  if Assigned(FTask) then
    FTask.FreeResources(True);
  {$ENDIF}
end;

procedure TStreamSocket.ExecuteWork;
begin
  // 直接调用 Server 的 OnDataReceive 事件（未必接收完毕）
  try
    FTickCount := GetTickCount;
    if Assigned(FServer.OnDataReceive) then
      FServer.OnDataReceive(Self, FRecvBuf^.Data.buf, FByteCount);
  finally
    {$IFDEF TRANSMIT_FILE}
    if (FTaskExists = False) then {$ENDIF}
      InternalRecv(True);  // 继续接收
  end;
end;

procedure TStreamSocket.PostEvent(IOKind: TIODataType);
begin
  // Empty
end;

{$IFDEF TRANSMIT_FILE}
procedure TStreamSocket.InterFreeRes;
begin
  // 释放 TransmitFile 的发送资源，继续投放接收！
  try
    ClearResources;
  finally
    InternalRecv(True);
  end;
end;
{$ENDIF}

procedure TStreamSocket.SendData(const Data: PAnsiChar; Size: Cardinal);
var
  Buf: PAnsiChar;
begin
  // 发送内存块数据（复制 Data）
  if Assigned(Data) and (Size > 0) then
  begin
    GetMem(Buf, Size);
    System.Move(Data^, Buf^, Size);
    {$IFDEF TRANSMIT_FILE}
    FTask.SetTask(Buf, Size);
    InterTransmit;
    {$ELSE}
    FSender.Send(Buf, Size);
    {$ENDIF}
  end;
end;

procedure TStreamSocket.SendData(const Msg: String);
begin
  // 发送文本
  if (Msg <> '') then
  begin
    {$IFDEF TRANSMIT_FILE}
    FTask.SetTask(Msg);
    InterTransmit;
    {$ELSE}
    FSender.Send(Msg);
    {$ENDIF}
  end;
end;

procedure TStreamSocket.SendData(Handle: THandle);
begin
  // 发送文件 handle（自动关闭）
  if (Handle > 0) and (Handle <> INVALID_HANDLE_VALUE) then
  begin
    {$IFDEF TRANSMIT_FILE}
    FTask.SetTask(Handle, GetFileSize64(Handle));
    InterTransmit;
    {$ELSE}
    FSender.Send(Handle, GetFileSize64(Handle));
    {$ENDIF}
  end;
end;

procedure TStreamSocket.SendData(Stream: TStream);
begin
  // 发送流数据（自动释放）
  if Assigned(Stream) then
  begin
    {$IFDEF TRANSMIT_FILE}
    FTask.SetTask(Stream, Stream.Size);
    InterTransmit;
    {$ELSE}
    FSender.Send(Stream, Stream.Size, True);
    {$ENDIF}
  end;
end;

procedure TStreamSocket.SendDataVar(Data: Variant);
begin
  // 发送可变类型数据
  if (VarIsNull(Data) = False) then
  begin
    {$IFDEF TRANSMIT_FILE}
    FTask.SetTaskVar(Data);
    InterTransmit;
    {$ELSE}
    FSender.SendVar(Data);
    {$ENDIF}
  end;
end;

{ TWebSocket }

procedure TWebSocket.ClearMsgOwner(Buf: PAnsiChar; Len: Integer);
begin
  // 修改消息的宿主
  Inc(Buf, Length(INIOCP_JSON_FLAG));
  if SearchInBuffer(Buf, Len, '"__MSG_OWNER":') then // 区分大小写
    while (Buf^ <> AnsiChar(',')) do
    begin
      Buf^ := AnsiChar('0');
      Inc(Buf);
    end;
end;

procedure TWebSocket.ClearResources;
begin
  if Assigned(FReceiver) then
    FReceiver.Clear;
end;

constructor TWebSocket.Create(APool: TIOCPSocketPool; ALinkNode: PLinkRec);
begin
  inherited;
  FUseTransObj := False;  // 不用 TransmitFile
  FJSON := TBaseJSON.Create(Self);
  FResult := TResultJSON.Create(Self);
  FResult.FServerMode := True;  // 服务器模式
  FReceiver := TWSServerReceiver.Create(Self, FJSON);
end;

destructor TWebSocket.Destroy;
begin
  FJSON.Free;
  FResult.Free;
  FReceiver.Free;
  inherited;
end;

procedure TWebSocket.ExecuteWork;
begin
  // 接收数据（与 TReceiveSocket 类似）

  // 1. 接收数据
  FTickCount := GetTickCount;

  if FReceiver.Complete then  // 首数据包
  begin
    // 分析、接收数据
    // 可能改变 FMsgType，见 FReceiver.UnMarkData
    FMsgType := mtDefault;
    FReceiver.Prepare(FRecvBuf^.Data.buf, FByteCount);
    case FReceiver.OpCode of
      ocClose: begin
        InterCloseSocket(Self);  // 关闭，返回
        Exit;
      end;
      ocPing, ocPong: begin
        InternalRecv(True);  // 投放，返回
        Exit;
      end;
    end;
  end else
  begin
    // 接收后续数据包
    FReceiver.Receive(FRecvBuf^.Data.buf, FByteCount);
  end;

  // 是否接收完成
  FComplete := FReceiver.Complete;

  // 2. 进入应用层
  // 2.1 标准操作，每接收一次即进入
  // 2.2 扩展的操作，是 JSON 消息，接收完毕才进入

  try
    if (FMsgType = mtDefault) or FComplete then
      FWorker.WSExecute(Self);
  finally
    if FComplete then   // 接收完毕
    begin
      case FMsgType of
        mtJSON: begin   // 扩展的 JSON
          FJSON.Clear;  // 不清 Attachment
          FResult.Clear;
          FReceiver.Clear;
        end;
        mtAttachment: begin  // 扩展的附件流
          FJSON.Close;  // 关闭附件流
          FResult.Clear;
          FReceiver.Clear;
        end;
      end;
      // ping 客户端
      InternalPing;  
    end;

    // 继续接收
    InternalRecv(FComplete);
  end;

end;

procedure TWebSocket.InternalPing;
begin
  // Ping 客户端，等新的信息缓存接收完成
  MakeFrameHeader(FSender.Data, ocPing);
  FSender.SendBuffers;
end;

procedure TWebSocket.InterPush(Target: TWebSocket);
var
  Msg: TPushMessage;
begin
  // 发收到的消息发给 Target 或广播
  //   提交到推送线程，不知道何时发出、是否成功。

  if (FOpCode <> ocText) then
  begin
    SendData('只能推送文本消息.');
    Exit;
  end;
    
  if (FComplete = False) or (FMsgSize > IO_BUFFER_SIZE - 30) then
  begin
    SendData('消息未完整接收或太长, 放弃.');
    Exit;
  end;

  // 清除掩码
  FReceiver.ClearMark(FData, @FRecvBuf^.Overlapped);

  if (FMsgType = mtJSON) then  // 清除 Owner, 0 表示服务端
    ClearMsgOwner(FData, FRecvBuf^.Overlapped.InternalHigh);

  if Assigned(Target) then  // 发给 Target
  begin
    Msg := TPushMessage.Create(FRecvBuf, False);
    Msg.Add(Target);  // 加入 Target
  end else  // 广播
    Msg := TPushMessage.Create(FRecvBuf, True);

  // 加入推送线程（必须发送一个消息给客户端）
  if FServer.PushManager.AddWork(Msg) then
    InternalPing  // Ping 客户端（延时，必须）
  else
    SendData('系统繁忙, 放弃.'); // 繁忙，放弃，Msg 已被释放

end;

procedure TWebSocket.PostEvent(IOKind: TIODataType);
begin
  // Empty
end;

procedure TWebSocket.SendData(const Msg: String);
begin
  // 未封装：发送文本
  if (Msg <> '') then
  begin
    FSender.OpCode := ocText;
    FSender.Send(System.AnsiToUtf8(Msg));
  end;
end;

procedure TWebSocket.SendData(const Data: PAnsiChar; Size: Cardinal);
var
  Buf: PAnsiChar;
begin
  // 未封装：发送内存块数据（复制 Data）
  if Assigned(Data) and (Size > 0) then
  begin
    GetMem(Buf, Size);
    System.Move(Data^, Buf^, Size);
    FSender.OpCode := ocBiary;
    FSender.Send(Buf, Size);
  end;
end;

procedure TWebSocket.SendData(Handle: THandle);
begin
  // 未封装：发送文件 handle（自动关闭）
  if (Handle > 0) and (Handle <> INVALID_HANDLE_VALUE) then
  begin
    FSender.OpCode := ocBiary;
    FSender.Send(Handle, GetFileSize64(Handle));
  end;
end;

procedure TWebSocket.SendData(Stream: TStream);
begin
  // 未封装：发送流数据（自动释放）
  if Assigned(Stream) then
  begin
    FSender.OpCode := ocBiary;
    FSender.Send(Stream, Stream.Size, True);
  end;
end;

procedure TWebSocket.SendDataVar(Data: Variant);
begin
  // 未封装：发送可变类型数据
  if (VarIsNull(Data) = False) then
  begin
    FSender.OpCode := ocBiary;
    FSender.SendVar(Data);
  end;
end;

procedure TWebSocket.SendResult(UTF8CharSet: Boolean);
begin
  // 发送 FResult 给客户端（InIOCP-JSON）
  FResult.FOwner := FJSON.Owner;
  FResult.FUTF8CharSet := UTF8CharSet;
  FResult.InternalSend(FSender, False);
end;

procedure TWebSocket.SetProps(AOpCode: TWSOpCode; AMsgType: TWSMsgType;
                     AData: Pointer; AFrameSize: Int64; ARecvSize: Cardinal);
begin
  // 更新，见：TWSServerReceiver.InitResources
  FMsgType := AMsgType;  // 数据类型
  FOpCode := AOpCode;  // 操作
  FMsgSize := 0;  // 消息长度
  FData := AData; // 引用地址
  FFrameSize := AFrameSize;  // 帧长度
  FFrameRecvSize := ARecvSize;  // 收到帧长度
end;

{ TIOCPSocket }

function TIOCPSocket.CheckMsgHead(InBuf: PAnsiChar): Boolean;
  function CheckLogState: TActionResult;
  begin
    // 检查登录状态
    if (FParams.Action = atUserLogin) then
      Result := arOK       // 通过
    else
    if (FParams.SessionId = 0) then
      Result := arErrUser  // 客户端不传递 SessionId, 当非法用户(
    else
    if (FParams.SessionId = INI_SESSION_ID) or
       (FParams.SessionId = FSessionId) then
      Result := arOK       // 通过
    else
    if SessionValid(FParams.SessionId) then
      Result := arOK       // 通过
    else
      Result := arOutDate; // 凭证过期
  end;
begin
  // 检查第一请求数据包的有效性、用户登录状态（类似于 http 协议）

  if (FByteCount < IOCP_SOCKET_SIZE) or  // 长度太短
     (MatchSocketType(InBuf, IOCP_SOCKET_FLAG) = False) then // C/S 标志错误
  begin
    // 关闭返回
    InterCloseSocket(Self);
    Result := False;
  end else
  begin
    // 发送器
    Result := True;
    FAction := atUnknown;  // 内部事件（用于附件传输）
    FResult.FSender := FSender;

    // 先更新协议头
    FParams.FMsgHead := PMsgHead(InBuf + IOCP_SOCKET_FLEN); // 推送时用
    FParams.SetHeadMsg(FParams.FMsgHead);
    FResult.SetHeadMsg(FParams.FMsgHead, True);

    if (FParams.Action = atUnknown) then  // 1. 响应服务
      FReceiver.Complete := True
    else begin
      // 2. 检查登录状态
      if Assigned(FServer.ClientManager) then
        FResult.ActResult := CheckLogState
      else begin // 免登录
        FResult.ActResult := arOK;
        if (FParams.FSessionId = INI_SESSION_ID) then
          FResult.FSessionId := CreateSession;
      end;
      if (FResult.ActResult in [arOffline, arOutDate]) then
        FReceiver.Complete := True  // 3. 接收完毕
      else // 4. 准备接收
        FReceiver.Prepare(InBuf, FByteCount);
    end;
  end;
end;

procedure TIOCPSocket.ClearResources;
begin
  // 清除资源
  if Assigned(FResult) then
    FReceiver.Clear;
  if Assigned(FParams) then
    FParams.Clear;
  if Assigned(FResult) then
    FResult.Clear;
  SetLogoutState;     // 登出
  {$IFDEF TRANSMIT_FILE}
  if Assigned(FTask) then  
    FTask.FreeResources(False);  // 已在 FResult.Clear 释放
  {$ENDIF}
end;

procedure TIOCPSocket.CreateResources;
begin
  // 建资源：接收、结果参数/变量表，数据接收器
  if (FReceiver = nil) then
  begin
    FParams := TReceiveParams.Create(Self);  // 在前
    FResult := TReturnResult.Create(Self);
    FReceiver := TServerReceiver.Create(FParams); // 在后
  end else
  if FReceiver.Complete then
  begin
    FParams.Clear;
    FResult.Clear;
  end;
end;

function TIOCPSocket.CreateSession: Cardinal;
var
  NowTime: TDateTime;
  Certify: TCertifyNumber;
begin
  // 生成一个登录凭证，有效期为 SESSION_TIMEOUT 分钟
  //   结构：(相对日序号 + 有效分钟) xor 年
  NowTime := Now();
  Certify.DayCount := Trunc(NowTime - 42500);  // 相对日序号
  Certify.Timeout := HourOf(NowTime) * 60 + MinuteOf(NowTime) + SESSION_TIMEOUT;
  Result := Certify.Session xor (Cardinal($A0250000) + YearOf(NowTime));
end;

destructor TIOCPSocket.Destroy;
begin
  // 释放资源
  if Assigned(FReceiver) then
  begin
    FReceiver.Free;
    FReceiver := Nil;
  end;
  if Assigned(FParams) then
  begin
    FParams.Free;
    FParams := Nil;
  end;
  if Assigned(FResult) then
  begin
    FResult.Free;
    FResult := Nil;
  end;
  inherited;
end;

procedure TIOCPSocket.ExecuteWork;
const
  IO_FIRST_PACKET = True;  // 首数据包
  IO_SUBSEQUENCE  = False; // 后续数据包
begin
  // 接收数据 FRecvBuf

  // 建资源
  CreateResources;   

  {$IFNDEF DELPHI_7}
  {$REGION '+ 接收数据'}
  {$ENDIF}
  
  // 1. 接收数据
  FTickCount := GetTickCount;
  
  case FReceiver.Complete of
    IO_FIRST_PACKET:  // 1.1 首数据包，检查有效性 和 用户登录状态
      if (CheckMsgHead(FRecvBuf^.Data.buf) = False) then
        Exit;
    IO_SUBSEQUENCE:   // 1.2 接收后续数据包
      FReceiver.Receive(FRecvBuf^.Data.buf, FByteCount);
  end;

  // 1.3 主体或附件接收完毕均进入应用层
  FComplete := FReceiver.Complete and (FReceiver.Cancel = False);

  {$IFNDEF DELPHI_7}
  {$ENDREGION}

  {$REGION '+ 进入应用层'}
  {$ENDIF}

  // 2. 进入应用层
  try
    if FComplete then   // 接收完毕、文件协议
      if FReceiver.CheckPassed then // 校验成功
        HandleDataPack  // 2.1 触发业务
      else
        ReturnMessage(arErrHash);  // 2.2 校验错误，反馈！
  finally
    // 2.3 继续投放 WSARecv，接收数据！
    {$IFDEF TRANSMIT_FILE}
    // 可能发出成功后任务被清在前！
    if (FTaskExists = False) then {$ENDIF}
      InternalRecv(FComplete);
  end;

  {$IFNDEF DELPHI_7}
  {$ENDREGION}
  {$ENDIF}

end;

procedure TIOCPSocket.HandleDataPack;
begin
  // 执行客户端请求

  // 1. 响应 -> 直接反馈协议头
  if (FParams.Action = atUnknown) then
    FResult.ReturnHead
  else

  // 2. 未登录（服务端不关闭）、对话过期 -> 反馈协议头
  if (FResult.ActResult in [arErrUser, arOutDate]) then
    ReturnMessage(FResult.ActResult)
  else

  // 3. 变量解析异常
  if FParams.Error then
    ReturnMessage(arErrAnalyse)
  else begin

    // 4. 进入应用层执行任务
    try
      FWorker.Execute(Self);
    except
      on E: Exception do  // 4.1 异常 -> 反馈
      begin
        ReturnMessage(arErrWork, E.Message);
        Exit;  // 4.2 返回
      end;
    end;

    try
      // 5. 主体+附件接收完毕 -> 清空
      FReceiver.OwnerClear;

      // 6. 非法用户，发送完毕要关闭
      if (FResult.ActResult = arErrUser) then
        windows.InterlockedIncrement(FState);  // FState+

      // 7. 发送结果！
      FResult.ReturnResult;

      {$IFNDEF TRANSMIT_FILE}
      // 7.1 发送完成事件（附件未关闭）
      if Assigned(FResult.Attachment) then
      begin
        FAction := atAfterSend;
        FWorker.Execute(Self);
      end;
      {$ENDIF}
    finally
      {$IFNDEF TRANSMIT_FILE}
      if (FReceiver.Complete = False) then  // 附件未接收完毕
        FAction := atAfterReceive;  // 恢复
      if Assigned(FResult.Attachment) then
        FResult.Clear;
      {$ENDIF}
    end;

  end;

end;

{$IFDEF TRANSMIT_FILE}
procedure TIOCPSocket.InterFreeRes;
begin
  // 释放 TransmitFile 的发送资源
  try
    try
      if Assigned(FResult.Attachment) then  // 附件发送完毕
      begin
        FAction := atAfterSend;
        FWorker.Execute(Self);
      end;
    finally
      if (FReceiver.Complete = False) then  // 附件未接收完毕
        FAction := atAfterReceive;  // 恢复
      FResult.NilStreams(True);     // 释放发送资源
      FTask.FreeResources(False);   // False -> 不用再释放
    end;
  finally  // 继续投放 Recv
    InternalRecv(FComplete);
  end;
end;
{$ENDIF}

procedure TIOCPSocket.PostEvent(IOKind: TIODataType);
var
  Msg: TPushMessage;
begin
  // 构造、推送一个协议头消息（给自己）
  //   C/S 服务 IOKind 只有 ioDelete、ioRefuse、ioTimeOut，
  //  其他消息用：Push(ATarget: TBaseSocket; UseUniqueMsgId: Boolean);
  //  同时开启 HTTP 服务时，会在 THttpSocket 发出 arRefuse（未转换资源）

  // 3 秒内活动过，取消超时
  if (IOKind = ioTimeOut) and CheckDelayed(GetTickCount) then
    Exit;

  Msg := TPushMessage.Create(Self, IOKind, IOCP_SOCKET_SIZE);

  case IOKind of
    ioDelete:
      THeadMessage.CreateHead(Msg.PushBuf^.Data.buf, arDeleted);
    ioRefuse: 
      THeadMessage.CreateHead(Msg.PushBuf^.Data.buf, arRefuse);
    ioTimeOut:
      THeadMessage.CreateHead(Msg.PushBuf^.Data.buf, arTimeOut);
  end;

  // 加入推送列表，激活推送线程
  FPushManager.AddWork(Msg);
end;

procedure TIOCPSocket.Push(Target: TIOCPSocket);
var
  Msg: TPushMessage;
begin
  // 发收到的消息给 Target 或广播
  //   提交到推送线程，不知道何时发出、是否成功。

  SetUniqueMsgId;  // 用唯一的 MsgID

  if Assigned(Target) then  // 发给 Target
  begin
    Msg := TPushMessage.Create(FRecvBuf, False);
    Msg.Add(Target);  // 加入 Target
  end else  // 广播
    Msg := TPushMessage.Create(FRecvBuf, True);

  // 加入推送线程
  if FServer.PushManager.AddWork(Msg) then
    Result.ActResult := arOK
  else
    Result.ActResult := arErrBusy; // 繁忙，放弃，Msg 已被释放
    
end;

procedure TIOCPSocket.SetLogoutState;
begin
  // 设置登出状态
  FSessionId := INI_SESSION_ID;
  if Assigned(FData) then
    if FData^.ReuseSession then  // 短连接断开，保留 FData 主要信息
    begin
      FData^.BaseInf.Socket := 0;
      FData^.BaseInf.LogoutTime := Now();
    end else
      try  // 释放登录信息
        FServer.ClientManager.ClientList.Remove(FData^.BaseInf.Name);
      finally
        FData := Nil;
      end;
end;

procedure TIOCPSocket.ReturnMessage(ActResult: TActionResult; const ErrMsg: String);
begin
  // 反馈协议头给客户端

  FParams.Clear;
  FResult.Clear;
  
  if (ErrMsg <> '') then
  begin
    FResult.ErrMsg := ErrMsg;
    FResult.ActResult := ActResult;
    FResult.ReturnResult;
  end else
    FResult.ReturnHead(ActResult);

  case ActResult of
    arOffline:
      iocp_log.WriteLog(Self.ClassName + '->客户端未登录.');
    arOutDate:
      iocp_log.WriteLog(Self.ClassName + '->凭证/认证过期.');
    arErrAnalyse:
      iocp_log.WriteLog(Self.ClassName + '->变量解析异常.');
    arErrHash:
      iocp_log.WriteLog(Self.ClassName + '->校验异常！');
    arErrWork:
      iocp_log.WriteLog(Self.ClassName + '->执行异常, ' + ErrMsg);
  end;

end;

procedure TIOCPSocket.SocketError(IOKind: TIODataType);
begin
  // 处理收发异常
  if (IOKind in [ioDelete, ioPush, ioRefuse]) then  // 推送
    FResult.ActResult := arErrPush;
  inherited;
end;

procedure TIOCPSocket.SetLogState(AData: PEnvironmentVar);
begin
  // 设置登录/登出信息
  if (AData = nil) then  // 登出
  begin
    SetLogoutState;
    FResult.FSessionId := FSessionId;
    FResult.ActResult := arLogout;  // 不是 arOffline
    if Assigned(FData) then  // 不关联到 Socket
      FData := nil;
  end else
  begin
    FSessionId := CreateSession;  // 重建对话期
    FResult.FSessionId := FSessionId;
    FResult.ActResult := arOK;
    FData := AData;
  end;
end;

procedure TIOCPSocket.SetUniqueMsgId;
begin
  // 设置推送消息的 MsgId
  //   推送消息改用服务器的唯一 MsgId
  
  {$IFDEF WIN64}
  FParams.FMsgId := System.AtomicIncrement(FServerMsgId);
  {$ELSE}
  FGlobalLock.Acquire;
  try
    Inc(FServerMsgId);
    FParams.FMsgId := FServerMsgId;
  finally
    FGlobalLock.Release;
  end;
  {$ENDIF}

  // 修改缓冲的 MsgId
  // 不要改 FResult.FMsgId，否则客户端把发送反馈当作推送消息处理
  FParams.FMsgHead^.MsgId := FParams.FMsgId;

end;

procedure TIOCPSocket.SetSocket(const Value: TSocket);
begin
  inherited;
  FSessionId := INI_SESSION_ID; // 初始凭证
end;

function TIOCPSocket.SessionValid(ASession: Cardinal): Boolean;
var
  NowTime: TDateTime;
  Certify: TCertifyNumber;
begin
  // 检查凭证是否正确且没超时
  //   结构：(相对日序号 + 有效分钟) xor 年
  NowTime := Now();
  Certify.Session := ASession xor (Cardinal($A0250000) + YearOf(NowTime));

  Result := (Certify.DayCount = Trunc(NowTime - 42500)) and
            (Certify.Timeout > HourOf(NowTime) * 60 + MinuteOf(NowTime));

  if Result then
    FSessionId := Certify.Session;
end;

{ THttpSocket }

procedure THttpSocket.ClearResources;
begin
  // 清除资源
  CloseStream;
  if Assigned(FRequest) then
    FRequest.Clear;
  if Assigned(FRespone) then
    FRespone.Clear;
  {$IFDEF TRANSMIT_FILE}
  if Assigned(FTask) then  
    FTask.FreeResources(False);  // 已在 FResult.Clear 释放
  {$ENDIF}    
end;

procedure THttpSocket.CloseStream;
begin
  if Assigned(FStream) then
  begin
    FStream.Free;
    FStream := Nil;
  end;
end;

procedure THttpSocket.CreateStream(const FileName: String);
begin
  // 建文件流
  FStream := TFileStream.Create(FileName, fmCreate or fmOpenWrite);
end;

procedure THttpSocket.DecodeHttpRequest;
begin
  // 请求命令解码（单数据包）
  //   在业务线程建 FRequest、FRespone，加快接入速度
  if (FRequest = nil) then
  begin
    FRequest := THttpRequest.Create(Self); // http 请求
    FRespone := THttpRespone.Create(Self); // http 应答
  end;
  // 更新时间、HTTP 命令解码
  FTickCount := GetTickCount;
  TRequestObject(FRequest).Decode(FSender, FRespone, FRecvBuf);
end;

destructor THttpSocket.Destroy;
begin
  CloseStream;
  if Assigned(FRequest) then
  begin
    FRequest.Free;
    FRequest := Nil;
  end;
  if Assigned(FRespone) then
  begin
    FRespone.Free;
    FRespone := Nil;
  end;
  inherited;
end;

procedure THttpSocket.ExecuteWork;
begin
  // 执行 Http 请求
  try
    // 0. 使用 C/S 协议时，要转换为 TIOCPSocket
    if (FTickCount = NEW_TICKCOUNT) and (FByteCount = IOCP_SOCKET_FLEN) and
      MatchSocketType(FRecvBuf^.Data.Buf, IOCP_SOCKET_FLAG) then
    begin
      UpgradeSocket(FServer.IOCPSocketPool);
      Exit;  // 返回
    end;

    // 1. 命令解码
    DecodeHttpRequest;

    // 2. 检查升级 WebSocket
    if (FRequest.UpgradeState > 0) then
    begin
      if FRequest.Accepted then  // 升级为 WebSocket，不能返回 THttpSocket 了
      begin
        TResponeObject(FRespone).Upgrade;
        UpgradeSocket(FServer.WebSocketPool);
      end else  // 不允许升级，关闭
        InterCloseSocket(Self);
      Exit;
    end;

    // 3. 执行业务
    FComplete := FRequest.Complete;   // 是否接收完毕
    FSessionId := FRespone.SessionId; // SendWork 时会被删除
    FRespone.StatusCode := FRequest.StatusCode;
   
    if FComplete and FRequest.Accepted and (FRequest.StatusCode < 400) then
      FWorker.HttpExecute(Self);

    // 4. 检查是否要保持连接
    if FRequest.Attacked then // 被攻击
      FKeepAlive := False
    else
      if FComplete or (FRespone.StatusCode >= 400) then  // 接收完毕或异常
      begin
        // 是否保存连接
        FKeepAlive := FRespone.KeepAlive;

        // 5. 发送内容给客户端
        TResponeObject(FRespone).SendWork;

        if {$IFNDEF TRANSMIT_FILE} FKeepAlive {$ELSE}
           (FTaskExists = False) {$ENDIF} then // 6. 清资源，准备下次请求
          ClearResources;
      end else
        FKeepAlive := True;   // 未完成，还不能关闭

    // 7. 继续投放或关闭
    if FKeepAlive and (FErrorCode = 0) then  // 继续投放
    begin
      {$IFDEF TRANSMIT_FILE}
      if (FTaskExists = False) then {$ENDIF}
        InternalRecv(FComplete);
    end else
      InterCloseSocket(Self);  // 关闭时清资源
                 
  except
    // 大并发时，在此设断点，调试是否异常
    iocp_log.WriteLog('THttpSocket.ExecuteHttpWork->' + GetSysErrorMessage);
    InterCloseSocket(Self);  // 系统异常
  end;

end;

{$IFDEF TRANSMIT_FILE}
procedure THttpSocket.InterFreeRes;
begin
  // 发送完毕，释放 TransmitFile 的发送资源
  try
    ClearResources;
  finally
    if FKeepAlive and (FErrorCode = 0) then  // 继续投放
      InternalRecv(True)
    else
      InterCloseSocket(Self);
  end;
end;
{$ENDIF}

procedure THttpSocket.PostEvent(IOKind: TIODataType);
const
  REQUEST_NOT_ACCEPTABLE = HTTP_VER + ' 406 Not Acceptable';
        REQUEST_TIME_OUT = HTTP_VER + ' 408 Request Time-out';
var
  Msg: TPushMessage;
  ResponeMsg: AnsiString;
begin
  // 构造、推送一个消息头（给自己）
  //   HTTP 服务只有 arRefuse、arTimeOut

  // TransmitFile 有任务或 3 秒内活动过，取消超时
  if (IOKind = ioTimeOut) and CheckDelayed(GetTickCount) then
    Exit;

  if (IOKind = ioRefuse) then
    ResponeMsg := REQUEST_NOT_ACCEPTABLE + STR_CRLF +
                  'Server: ' + HTTP_SERVER_NAME + STR_CRLF +
                  'Date: ' + GetHttpGMTDateTime + STR_CRLF +
                  'Content-Length: 0' + STR_CRLF +
                  'Connection: Close' + STR_CRLF2
  else
    ResponeMsg := REQUEST_TIME_OUT + STR_CRLF +
                  'Server: ' + HTTP_SERVER_NAME + STR_CRLF +
                  'Date: ' + GetHttpGMTDateTime + STR_CRLF +
                  'Content-Length: 0' + STR_CRLF +
                  'Connection: Close' + STR_CRLF2;

  Msg := TPushMessage.Create(Self, IOKind, Length(ResponeMsg));

  System.Move(ResponeMsg[1], Msg.PushBuf^.Data.buf^, Msg.PushBuf^.Data.len);

  // 加入推送列表，激活线程
  FPushManager.AddWork(Msg);
end;

procedure THttpSocket.SocketError(IOKind: TIODataType);
begin
  // 处理收发异常
  if Assigned(FRespone) then      // 接入时 = Nil
    FRespone.StatusCode := 500;   // 500: Internal Server Error
  inherited;
end;

procedure THttpSocket.UpgradeSocket(SocketPool: TIOCPSocketPool);
var
  oSocket: TBaseSocket;
begin
  // 把 THttpSocket 转换为 TIOCPSocket、TWebSocket，
  try
    oSocket := TBaseSocket(SocketPool.Clone(Self));  // 未建 FTask！
    oSocket.PostRecv;  // 投放
  finally
    InterCloseSocket(Self);  // 关闭自身
  end;
end;

procedure THttpSocket.WriteStream(Data: PAnsiChar; DataLength: Integer);
begin
  // 保存数据到文件流
  if Assigned(FStream) then
    FStream.Write(Data^, DataLength);
end;

{ TSocketBroker }

procedure TSocketBroker.AssociateInner(InnerBroker: TSocketBroker);
begin
  // 和内部连接关联起来（已经投放 WSARecv）
  if (InnerBroker.ErrorCode = 0) then
  begin
    FDual := InnerBroker;
    FToSocket := InnerBroker.FSocket;

    InnerBroker.FDual := Self;
    InnerBroker.FToSocket := FSocket;
    InnerBroker.FState := 1;  // 加锁
    
    InnerBroker.FBrokerId := FBrokerId;
    InnerBroker.FTargetHost := FTargetHost;
    InnerBroker.FTargetPort := FTargetPort;

    FDual.FOnBind := nil;  // 删除
  end;
  if (FSocketType = stWebSocket) or (FIOCPBroker.Protocol = tpNone) then
    FOnBind := nil;  // 删除绑定事件，以后不再绑定！
end;

function TSocketBroker.ChangeConnection(const ABrokerId, AServer: AnsiString; APort: Integer): Boolean;
begin
  // 检查关联是否已经改变
  if (FIOCPBroker.ProxyType = ptOuter) then
    Result := (ABrokerId <> FBrokerId)  // 反向代理改变
  else
    Result := not (((AServer = FTargetHost) or
                    (LowerCase(AServer) = 'localhost') and (FTargetHost = '127.0.0.1') or
                    (LowerCase(FTargetHost) = 'localhost') and (AServer = '127.0.0.1')) and (
                    (APort = FTargetPort) or (APort = FServer.ServerPort)));
end;

function TSocketBroker.CheckInnerSocket: Boolean;
begin
  // ++外部代理模式
  if (PInIOCPInnerSocket(FRecvBuf^.Data.buf)^ = InIOCP_INNER_SOCKET) then
  begin
    // 这是内部的反向代理连接，保存到列表
    SetString(FBrokerId, FRecvBuf^.Data.buf + Length(InIOCP_INNER_SOCKET) + 1,
                         Integer(FByteCount) - Length(InIOCP_INNER_SOCKET) - 1);
    TInIOCPBrokerX(FIOCPBroker).AddConnection(Self, FBrokerId);
    Result := True;
  end else
    Result := False;  // 这是外部的客户端连接
end;

procedure TSocketBroker.ClearResources;
begin
  // 反向代理，未关联的连接被断开，向外补发连接
  if FIOCPBroker.ReverseMode and (FSocketType = stOuterSocket) then
    TInIOCPBrokerX(FIOCPBroker).ConnectOuter;
  if Assigned(FDual) then  // 尝试关闭
    FDual.TryClose;
end;

procedure TSocketBroker.CreateBroker(const AServer: AnsiString; APort: Integer);
begin
  // 新建一个内部代理（中继套接字）

  if Assigned(FDual) then  
  begin
    if (FDual.ChangeConnection(FBrokerId, AServer, APort) = False) then
      Exit;
    FDual.InternalClose;  // 关闭
  end else  // 新建内部代理
    FDual := TSocketBroker(FPool.Pop^.Data);

  // 建套接字
  FDual.SetSocket(iocp_utils.CreateSocket);

  if ConnectSocket(FDual.FSocket, AServer, APort) and  // 连接
    FServer.IOCPEngine.BindIoCompletionPort(FDual.FSocket) then  // 绑定
  begin
    FTargetHost := AServer;
    FTargetPort := APort;
    FToSocket := FDual.FSocket;

    // 关联起来
    FDual.FDual := Self;
    FDual.FToSocket := FSocket;

    FDual.FBrokerId := FBrokerId;
    FDual.FTargetPort := APort;
    FDual.FTargetHost := AServer;
    FDual.FOnBind := nil;  // 删除

    // 投放
    FDual.PostRecv;
    FDual.FState := 1;  // 加锁    
    FErrorCode := FDual.ErrorCode;
  end else
    FErrorCode := GetLastError;

  if (FErrorCode > 0) then  // 关闭代理
  begin
    FDual.FDual := nil;
    FDual.InternalClose;
    FDual.InterCloseSocket(FDual);
    FDual := nil;
  end;

  // 反向代理，向外补发连接
  if FIOCPBroker.ReverseMode then
  begin
    FSocketType := stDefault;  // 改变，关闭时不补充连接
    TInIOCPBrokerX(FIOCPBroker).ConnectOuter;
  end;

  if (FSocketType = stWebSocket) or (FIOCPBroker.Protocol = tpNone) then
    FOnBind := nil;  // 删除绑定事件，以后不再绑定！

end;

procedure TSocketBroker.ExecuteWork;
begin
  // 执行：
  //   1、绑定、关联，发送外部数据到 FDual
  //   2、已经关联时直接发送到 FDual
  
  if (FConnected = False) then
    Exit;

  // 要合理设置 TInIOCPBroker.ProxyType 
  case FIOCPBroker.ProxyType of
    ptDefault:
      if (FAction > 0) then  // 见：SendInnerFlag
      begin
        ExecSocketAction;    // 执行操作，返回
        InternalRecv(True);
        Exit;
      end;
    ptOuter:  // 外部代理
      if not Assigned(FDual) and CheckInnerSocket then  // 检查连接类型
      begin
        InternalRecv(True);  // 先投放
        Exit;
      end;
  end;

  if Assigned(FOnBind) then
    try
      FOnBind(Self, FRecvBuf^.Data.buf, FByteCount)  // 绑定、关联
    finally
      if Assigned(FDual) then
        ForwardData  // 转发数据
      else
        InterCloseSocket(Self);
    end
  else
    if Assigned(FDual) then
      ForwardData;  // 转发数据

end;

procedure TSocketBroker.ExecSocketAction;
begin
  // 发送内部连接标志到外部代理
  try
    if (FIOCPBroker.BrokerId = '') then  // 用默认标志
      FSender.Send(InIOCP_INNER_SOCKET + ':DEFAULT')
    else  // 同时发送代理标志，方便外部代理区分
      FSender.Send(InIOCP_INNER_SOCKET + ':' + UpperCase(FIOCPBroker.BrokerId));
  finally
    FAction := 0;
  end;
end;

procedure TSocketBroker.ForwardData;
  procedure ResetDualState;
  begin
    if (windows.InterlockedDecrement(FDual.FState) <> 0) then
      FDual.InterCloseSocket(FDual);
  end;
begin
  // 复制、转发数据（不能简单互换数据块，否则大并发时 995 异常）:
  try
    FSender.Socket := FToSocket;  // 改变（原来为自己的）
    TServerTaskSender(FSender).CopySend(FRecvBuf);
  finally
    if (FErrorCode = 0) then
    begin
      InternalRecv(FComplete);
      ResetDualState;
    end else
    begin
      ResetDualState;    
      InterCloseSocket(Self);
    end;
  end;
end;

procedure TSocketBroker.HttpConnectHost(const AServer: AnsiString; APort: Integer);
begin
  // Http 协议：连接到请求的主机 HOST，没有时连接到参数指定的
  if (FTargetHost <> '') and (FTargetPort > 0) then
    CreateBroker(FTargetHost, FTargetPort)
  else
  if (AServer <> '') and (APort > 0) then  // 用参数指定的
    CreateBroker(AServer, APort)
  else
    InterCloseSocket(Self);  // 关闭
end;

procedure TSocketBroker.HttpRequestDecode;
  procedure GetHttpHost(var p: PAnsiChar);
  var
    pb: PAnsiChar;
  begin
    // 提取主机地址：HOST:
    pb := nil;
    Inc(p, 4);
    repeat
      case p^ of
        ':':
          if (pb = nil) then
            pb := p + 1;
        #13: begin
          SetString(FTargetHost, pb, p - pb);
          FTargetHost := Trim(FTargetHost);
          Exit;
        end;
      end;
      Inc(p);
    until (p^ = #10);
  end;
  procedure GetContentLength(var p: PAnsiChar);
  var
    S: AnsiString;
    pb: PAnsiChar;
  begin
    // 提取内容长度：CONTENT-LENGTH: 1234
    pb := nil;
    Inc(p, 14);
    repeat
      case p^ of
        ':':
          pb := p + 1;
        #13: begin
          SetString(S, pb, p - pb);
          TryStrToInt(S, FContentLength);
          Exit;
        end;
      end;
      Inc(p);
    until (p^ = #10);
  end;
  procedure GetUpgradeType(var p: PAnsiChar);
  var
    S: AnsiString;
    pb: PAnsiChar;
  begin
    // 提取内容长度：UPGRADE: WebSocket
    pb := nil;
    Inc(p, 14);
    repeat
      case p^ of
        ':':
          pb := p + 1;
        #13: begin
          SetString(S, pb, p - pb);
          if (UpperCase(Trim(S)) = 'WEBSOCKET') then
            FSocketType := stWebSocket;
          Exit;
        end;
      end;
      Inc(p);
    until (p^ = #10);
  end;
  procedure ExtractHostPort;
  var
    i, j, k: Integer;
  begin
    // 分离 Host、Port 和 局域网标志

    j := 0;
    k := 0;

    for i := 1 to Length(FTargetHost) do  // 127.0.0.1:800@DEFAULT
      case FTargetHost[i] of
        ':':
          j := i;
        '@':
          k := i;
      end;

    if (k > 0) then  // 反向代理标志
    begin
      if (FIOCPBroker.ProxyType = ptOuter) then  // 外部才用
        FBrokerId := Copy(FTargetHost, k + 1, 99);
      Delete(FTargetHost, k, 99);
    end;

    if (j > 0) then  // 内部主机
    begin
      TryStrToInt(Copy(FTargetHost, j + 1, 99), FTargetPort);
      Delete(FTargetHost, j, 99);
    end;
    
  end;

var
  iState: Integer;
  pE, pb, p: PAnsiChar;
begin
  // Http 协议：提取请求信息：Host、Content-Length、Upgrade

  FContentLength := 0;  // 总长
  FReceiveSize := 0;    // 收到的长度
  iState := 0;          // 信息状态

  p := FRecvBuf^.Data.buf;  // 开始位置
  pE := PAnsiChar(p + FByteCount);  // 结束位置
  pb := nil;
  
  Inc(p, 12);

  repeat
    case p^ of
      #10:  // 分行符
        pb := p + 1;

      #13:  // 回车符
        if (pb <> nil) then
          if (p = pb) then  // 出现连续的回车换行，报头结束
          begin
            Inc(p, 2);
            if (p < pE) then  // 后面带数据，POST
              FReceiveSize := pE - p;
            Break;
          end else
          if (p - pb >= 15) then
          begin
            if http_utils.CompareBuffer(pb, 'HOST', True) then
            begin
              iState := iState xor 1;
              GetHttpHost(pb);
              ExtractHostPort;
            end else
            if http_utils.CompareBuffer(pb, 'CONTENT-LENGTH', True) then
            begin
              iState := iState xor 2;
              GetContentLength(pb);
            end else
            if http_utils.CompareBuffer(pb, 'UPGRADE', True) then  // WebSocket
            begin
              iState := iState xor 2;
              GetUpgradeType(pb);
            end;
          end;
    end;

    Inc(p);
  until (p >= pE) or (iState = 3);

  // 用默认主机
  if (FIOCPBroker.ProxyType = ptDefault) then
  begin
    if (FTargetHost = '') then
      FTargetHost := FIOCPBroker.DefaultInnerAddr;
    if (FTargetPort = 0) then
      FTargetPort := FIOCPBroker.DefaultInnerPort;
  end;

  // 是否传输完成
  FComplete := FReceiveSize >= FContentLength;

end;

function TSocketBroker.Lock(PushMode: Boolean): Integer;
const
  SOCKET_STATE_IDLE  = 0;  // 空闲
  SOCKET_STATE_BUSY  = 1;  // 在用
  SOCKET_STATE_TRANS = 2;  // TransmitFile 在用 
begin
  // 覆盖基类方法，没有推送模式
  case iocp_api.InterlockedCompareExchange(FState, 1, 0) of  // 返回原值

    SOCKET_STATE_IDLE: begin
      if not Assigned(FDual) or
        (iocp_api.InterlockedCompareExchange(FDual.FState, 1, 0) = SOCKET_STATE_IDLE) then
        Result := SOCKET_LOCK_OK
      else
        Result := SOCKET_LOCK_FAIL;
      if (Result = SOCKET_LOCK_FAIL) then // 放弃！
        if (windows.InterlockedDecrement(FState) <> 0) then
          InterCloseSocket(Self);
    end;

    SOCKET_STATE_BUSY,
    SOCKET_STATE_TRANS:
      Result := SOCKET_LOCK_FAIL;  // 在用

    else
      Result := SOCKET_LOCK_CLOSE; // 已关闭或工作中异常
  end;
end;

procedure TSocketBroker.HttpBindOuter(Connection: TSocketBroker; const Data: PAnsiChar; DataSize: Cardinal);
begin
  // Http 协议：外部客户端传来数据，关联内部连接
  if FComplete then  // 新的请求
  begin
    HttpRequestDecode;  // 提取信息
    if (FIOCPBroker.ProxyType = ptDefault) then  // 新建连接，关联
      HttpConnectHost(FIOCPBroker.InnerServer.ServerAddr,
                      FIOCPBroker.InnerServer.ServerPort)
    else  // 从内部连接池选取关联对象
    if not Assigned(FDual) or FDual.ChangeConnection(FBrokerId, FTargetHost, FTargetPort) then
      TInIOCPBrokerX(FIOCPBroker).BindBroker(Connection, Data, DataSize);
  end else
  begin  // 收到的当前请求的实体内容+
    Inc(FReceiveSize, FByteCount);
    FComplete := FReceiveSize >= FContentLength;
  end;
end;

procedure TSocketBroker.PostEvent(IOKind: TIODataType);
begin
  InterCloseSocket(Self);  // 直接关闭，见 TInIOCPServer.AcceptClient
end;

procedure TSocketBroker.SendInnerFlag;
begin
  // 向外部代理发送连接标志
  FAction := 1;  // 自身操作
  FState := 0;
  FRecvBuf^.RefCount := 1;
  FServer.BusiWorkMgr.AddWork(Self);
end;

procedure TSocketBroker.SetConnection(Connection: TSocket);
begin
  // 反向代理：设置主动发起到外部的连接
  SetSocket(Connection);
  FSocketType := stOuterSocket;  // 连接到外部的
  if (FIOCPBroker.Protocol = tpNone) then 
    FOnBind := FIOCPBroker.OnBind; // 绑定关联事件
end;

procedure TSocketBroker.SetSocket(const Value: TSocket);
begin
  inherited;

  FDual := nil;
  FTargetHost := '';
  FTargetPort := 0;
  FToSocket := INVALID_SOCKET;
  FUseTransObj := False;  // 不用 TransmitFile

  // 默认的 FBrokerId
  if (FIOCPBroker.ProxyType = ptOuter) then
    FBrokerId := 'DEFAULT';

  if (FIOCPBroker.Protocol = tpHTTP) then  // http 协议，直接内部绑定、解析
    FOnBind := HttpBindOuter
  else
  if (FIOCPBroker.ProxyType = ptDefault) then
    FOnBind := FIOCPBroker.OnBind  // 绑定关联事件
  else // 外部代理，自动绑定
    FOnBind := TInIOCPBrokerX(FIOCPBroker).BindBroker;
end;

end.
