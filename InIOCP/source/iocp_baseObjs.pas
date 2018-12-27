(*
 * iocp 线程锁、线程基类
 *)
unit iocp_baseObjs;

interface

{$I in_iocp.inc}        // 模式设置

uses
  Windows, Classes, SysUtils, ActiveX,
  iocp_log;

type

  // ===================== 线程锁 类 =====================

  TThreadLock = class(TObject)
  protected
    FSection: TRTLCriticalSection;
  public
    constructor Create;
    destructor Destroy; override;
  public
    procedure Acquire; {$IFDEF USE_INLINE} inline; {$ENDIF}
    procedure Release; {$IFDEF USE_INLINE} inline; {$ENDIF}
  end;

  // ===================== 线程基类 ===================== 

  TBaseThread = class(TThread)
  protected
    procedure Execute; override;
    procedure ExecuteWork; virtual; abstract;   // 在子类继承
  end;

  // ===================== 循环执行任务的线程 =====================

  TCycleThread = class(TBaseThread)
  protected
    FInHandle: Boolean;   // 内含信号灯
    FSemaphore: THandle;  // 信号灯
    procedure AfterWork; virtual; abstract;
    procedure DoMethod; virtual; abstract;
    procedure ExecuteWork; override;
  public
    constructor Create(InHandle: Boolean = True);
    destructor Destroy; override;
    procedure Activate; {$IFDEF USE_INLINE} inline; {$ENDIF}
    procedure Stop;
  end;

implementation

{ TThreadLock }

procedure TThreadLock.Acquire;
begin
  EnterCriticalSection(FSection);
end;

constructor TThreadLock.Create;
begin
  inherited Create;
  InitializeCriticalSection(FSection);
end;

destructor TThreadLock.Destroy;
begin
  DeleteCriticalSection(FSection);
  inherited;
end;

procedure TThreadLock.Release;
begin
  LeaveCriticalSection(FSection);
end;

{ TBaseThread }

procedure TBaseThread.Execute;
begin
  inherited;
  CoInitializeEx(Nil, 0);
  try
    ExecuteWork;
  finally
    CoUninitialize;
  end;
end;

{ TCycleThread }

procedure TCycleThread.Activate;
begin
  // 信号量+，激活线程
  ReleaseSemapHore(FSemaphore, 8, Nil);
end;

constructor TCycleThread.Create(InHandle: Boolean);
begin
  inherited Create(True);
  FreeOnTerminate := True;
  FInHandle := InHandle;
  if FInHandle then
    FSemaphore := CreateSemapHore(Nil, 0, MaxInt, Nil);  // 信号最大值 = MaxInt
end;

destructor TCycleThread.Destroy;
begin
  if FInHandle then
    CloseHandle(FSemaphore);
  inherited;
end;

procedure TCycleThread.ExecuteWork;
begin
  inherited;
  try
    while (Terminated = False) do
      if (WaitForSingleObject(FSemaphore, INFINITE) = WAIT_OBJECT_0) then  // 等待信号灯
        try
          DoMethod;  // 执行子类方法
        except
          on E: Exception do
            iocp_log.WriteLog(Self.ClassName + '->循环线程异常: ' + E.Message);
        end;
  finally
    AfterWork;
  end;
end;

procedure TCycleThread.Stop;
begin
  Terminate;
  Activate;
end;

end.
