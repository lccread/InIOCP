(*
 * iocp �߳������̻߳���
 *)
unit iocp_baseObjs;

interface

{$I in_iocp.inc}        // ģʽ����

uses
  Windows, Classes, SysUtils, ActiveX,
  iocp_log;

type

  // ===================== �߳��� �� =====================

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

  // ===================== �̻߳��� ===================== 

  TBaseThread = class(TThread)
  protected
    procedure Execute; override;
    procedure ExecuteWork; virtual; abstract;   // ������̳�
  end;

  // ===================== ѭ��ִ��������߳� =====================

  TCycleThread = class(TBaseThread)
  protected
    FInHandle: Boolean;   // �ں��źŵ�
    FSemaphore: THandle;  // �źŵ�
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
  // �ź���+�������߳�
  ReleaseSemapHore(FSemaphore, 8, Nil);
end;

constructor TCycleThread.Create(InHandle: Boolean);
begin
  inherited Create(True);
  FreeOnTerminate := True;
  FInHandle := InHandle;
  if FInHandle then
    FSemaphore := CreateSemapHore(Nil, 0, MaxInt, Nil);  // �ź����ֵ = MaxInt
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
      if (WaitForSingleObject(FSemaphore, INFINITE) = WAIT_OBJECT_0) then  // �ȴ��źŵ�
        try
          DoMethod;  // ִ�����෽��
        except
          on E: Exception do
            iocp_log.WriteLog(Self.ClassName + '->ѭ���߳��쳣: ' + E.Message);
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