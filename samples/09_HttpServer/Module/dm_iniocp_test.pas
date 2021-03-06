unit dm_iniocp_test;

interface

uses
  // 使用时请加单元引用 MidasLib！
  Windows, Messages, SysUtils, Variants, Classes, Graphics,
  Controls, Forms, Dialogs, DB, DBClient, Provider,
  {$IFDEF VER320} Data.Win.ADODB {$ELSE} ADODB {$ENDIF},  // 高版本是 Data.Win.ADODB
  iocp_baseModule, iocp_base, iocp_objPools, iocp_sockets,
  iocp_sqlMgr, http_base, http_objects, iocp_WsJSON, MidasLib;

type

  // 数据库操作
  // 从 iocp_baseModule.TInIOCPDataModule 继承新建

  // 操作数据库的事件属性包括：
  //   OnApplyUpdates、OnExecQuery、OnExecSQL、OnExecStoredProcedure
  //   OnHttpExecQuery、OnHttpExecSQL

  TdmInIOCPTest = class(TInIOCPDataModule)
    DataSetProvider1: TDataSetProvider;
    InSQLManager1: TInSQLManager;
    procedure InIOCPDataModuleCreate(Sender: TObject);
    procedure InIOCPDataModuleDestroy(Sender: TObject);
    procedure InIOCPDataModuleApplyUpdates(const Delta: OleVariant;
      out ErrorCount: Integer; AResult: TReturnResult);
    procedure InIOCPDataModuleExecQuery(AParams: TReceiveParams;
      AResult: TReturnResult);
    procedure InIOCPDataModuleExecSQL(AParams: TReceiveParams;
      AResult: TReturnResult);
    procedure InIOCPDataModuleExecStoredProcedure(AParams: TReceiveParams;
      AResult: TReturnResult);
    procedure InIOCPDataModuleHttpExecQuery(Sender: TObject;
      Request: THttpRequest; Respone: THttpRespone);
    procedure InIOCPDataModuleHttpExecSQL(Sender: TObject;
      Request: THttpRequest; Respone: THttpRespone);
    procedure InIOCPDataModuleWebSocketQuery(Sender: TObject; JSON: TBaseJSON;
      Result: TResultJSON);
    procedure InIOCPDataModuleWebSocketUpdates(Sender: TObject; JSON: TBaseJSON;
      Result: TResultJSON);
  private
    { Private declarations }
    FConnection: TADOConnection;
    FQuery: TADOQuery;
    FExecSQL: TADOCommand;
    FCurrentSQLName: String;
    procedure CommitTransaction;
  public
    { Public declarations }
  end;

{ var
    dmInIOCPTest: TdmInIOCPTest; // 注解, 注册到系统后自动建实例 }

implementation

uses
  iocp_Varis, iocp_utils;

{$R *.dfm}

procedure TdmInIOCPTest.CommitTransaction;
begin
//  GlobalLock.Acquire;   // Ado 无需加锁
//  try
    if FConnection.InTransaction then
      FConnection.CommitTrans;
    if not FConnection.InTransaction then
      FConnection.BeginTrans;
{  finally
    GlobalLock.Release;
  end;  }
end;

procedure TdmInIOCPTest.InIOCPDataModuleApplyUpdates(const Delta: OleVariant;
  out ErrorCount: Integer; AResult: TReturnResult);
begin
  // 用 DataSetPrivoder.Delta 更新

  if not FConnection.InTransaction then
    FConnection.BeginTrans;

  try
    try
      DataSetProvider1.ApplyUpdates(Delta, 0, ErrorCount);
    finally
      if ErrorCount = 0 then
      begin
        CommitTransaction;
        AResult.ActResult := arOK;
      end else
      begin
        if FConnection.InTransaction then
          FConnection.RollbackTrans;
        AResult.ActResult := arFail;
        AResult.AsInteger['ErrorCount'] := ErrorCount;
      end;
    end;
  except
    if FConnection.InTransaction then
      FConnection.RollbackTrans;
    Raise;    // 基类有异常处理，要 Raise
  end;
end;

procedure TdmInIOCPTest.InIOCPDataModuleCreate(Sender: TObject);
begin
  inherited;

  // 用 InSQLManager1.SQLs 装入 SQL 资源文件（文本文件）
  InSQLManager1.SQLs.LoadFromFile('sql\' + ClassName + '.sql');

  // 为方便编译，新版本改用 ADO 连接 access 数据库（内含行政区划数据表）
  FConnection := TADOConnection.Create(Self);
  FConnection.LoginPrompt := False;

  // 注册 Access-ODBC、设置 ODBC 连接
  if DirectoryExists('data') then
    RegMSAccessDSN('acc_db', iocp_varis.gAppPath + 'data\acc_db.mdb', 'InIOCP测试')
  else  // 发布为例子时
    RegMSAccessDSN('acc_db', iocp_varis.gAppPath + '..\00_data\acc_db.mdb', 'InIOCP测试');
    
  SetMSAccessDSN(FConnection, 'acc_db');
  
  FQuery := TADOQuery.Create(Self);
  FExecSQL := TADOCommand.Create(Self);

  FQuery.Connection := FConnection;
  FExecSQL.Connection := FConnection;

  // 自动解析 SQL 参数
  FQuery.ParamCheck := True;
  FExecSQL.ParamCheck := True;

  DataSetProvider1.DataSet := FQuery;
  FConnection.Connected := True;
end;

procedure TdmInIOCPTest.InIOCPDataModuleDestroy(Sender: TObject);
begin
  inherited;
  FQuery.Free;
  FExecSQL.Free;
  FConnection.Free;
end;

procedure TdmInIOCPTest.InIOCPDataModuleExecQuery(AParams: TReceiveParams;
  AResult: TReturnResult);
var
  SQLName: String;
begin
  // 查询数据
  // 基类有异常处理

  if not FConnection.InTransaction then
    FConnection.BeginTrans;

  // 2.0 预设了 SQL、SQLName 属性
  //     查找服务端名称为 SQLName 的 SQL 语句，执行
  //     要和客户端的命令配合

  SQLName := AParams.SQLName;
  if (SQLName = '') then  // 改用 SQL（未必就是 SELECT-SQL）
    with FQuery do
    begin
      SQL.Clear;
      SQL.Add(AParams.SQL);
      Active := True;
    end
  else
  if (SQLName <> FCurrentSQLName) then
  begin
    FCurrentSQLName := SQLName;
    with FQuery do
    begin
      SQL.Clear;
      SQL.Add(InSQLManager1.GetSQL(SQLName));
      Active := True;
    end;
  end;

  // 把数据集 Data 转换为流（自动压缩），返回给客户端，执行结果为 arOK
  AResult.LoadFromVariant(DataSetProvider1.Data);
  AResult.ActResult := arOK;

  FQuery.Active := False;   // 关闭
end;

procedure TdmInIOCPTest.InIOCPDataModuleExecSQL(AParams: TReceiveParams;
  AResult: TReturnResult);
var
  SQLName: string;
begin
  // 执行 SQL
  // 基类有异常处理
  if not FConnection.InTransaction then
    FConnection.BeginTrans;

  try

    // 取 SQL
    SQLName := AParams.SQLName;
    if (SQLName = '') then  // 用 SQL
      FExecSQL.CommandText := AParams.SQL
    else
    if (SQLName <> FCurrentSQLName) then  // 用名称
    begin
      FCurrentSQLName := SQLName;
      FExecSQL.CommandText := InSQLManager1.GetSQL(SQLName);
    end;

    if not AParams.HasParams then  // 客户端设定“没有参数”
    begin
      FExecSQL.Execute;  // 直接执行
    end else
      with FExecSQL do
      begin  // 参数赋值
        Parameters.ParamByName('picutre').LoadFromStream(AParams.AsStream['picture'], ftBlob);
        Parameters.ParamByName('code').Value := AParams.AsString['code'];
        Execute;
      end;

    CommitTransaction;
    AResult.ActResult := arOK;  // 执行成功 arOK
  except
    if FConnection.InTransaction then
      FConnection.RollbackTrans;
    Raise;    // 基类有异常处理，要 Raise
  end;
end;

procedure TdmInIOCPTest.InIOCPDataModuleExecStoredProcedure(
  AParams: TReceiveParams; AResult: TReturnResult);
begin
  // 执行存储过程
  try
    // 这是存储过程名称：
    // ProcedureName := AParams.StoredProcName;
    // 见：TInDBQueryClient.ExecStoredProc
    //     TInDBSQLClient.ExecStoredProc

    // 这样返回数据集：
    // AResult.LoadFromVariant(DataSetProvider1.Data);

    if AParams.StoredProcName = 'ExecuteStoredProc2' then  // 测试存储过程（数据未实现）
      InIOCPDataModuleExecQuery(AParams, AResult)     // 返回一个数据集
    else
      AResult.ActResult := arOK;
  except
    if FConnection.InTransaction then
      FConnection.RollbackTrans;
    Raise;    // 基类有异常处理，要 Raise
  end;
end;

procedure TdmInIOCPTest.InIOCPDataModuleHttpExecQuery(Sender: TObject;
  Request: THttpRequest; Respone: THttpRespone);
var
  i: Integer;
  SQLName: String;
begin
  // Http 服务：在这里执行 SQL 查询，用 Respone 返回结果
  with FQuery do
  try
    try

      // 用 SQL 名称查找对应的 SQL 文本
      // Http 的 Request.Params 没有预设 sql, sqlName 属性
      SQLName := Request.Params.AsString['SQL'];

      if (FCurrentSQLName <> SQLName) then   // 名称改变，重设 SQL
      begin
        SQL.Clear;
        SQL.Add(InSQLManager1.GetSQL(SQLName));
        FCurrentSQLName := SQLName;
      end;

      // 用 Request.ConectionState 或 Respone.ConectionState
      // 检查连接状态是否正常, 不正常无需再查询发送
      if Request.SocketState then  // 旧版：ConnectionState
      begin
        // 通用一点的赋值方法：
        // Select xxx from ttt where code=:code and no=:no and datetime=:datetime
        for i := 0 to Parameters.Count - 1 do
          Parameters.Items[i].Value := Request.Params.AsString[Parameters.Items[i].Name];
        Active := True;
      end;

      // 转换全部记录为 JSON，用 Respone 返回
      //   小数据集可用：
      //      Respone.CharSet := hcsUTF8;  // 指定字符集
      //      Respone.SendJSON(iocp_utils.DataSetToJSON(FQuery, Respone.CharSet))
      //   推荐用 Respone.SendJSON(FQuery)，分块发送
      // 见：iocp_utils 单元 DataSetToJSON、LargeDataSetToJSON、InterDataSetToJSON
      if Request.SocketState then
      begin
        Respone.SendJSON(FQuery);  // 用默认字符集 gb2312
//        Respone.SendJSON(FQuery, hcsUTF8);  // 转为 UTF-8 字符集
      end;

    finally
      Active := False;
    end;
  except
    Raise;
  end;
end;

procedure TdmInIOCPTest.InIOCPDataModuleHttpExecSQL(Sender: TObject;
  Request: THttpRequest; Respone: THttpRespone);
begin
  // Http 服务：在这里执行 SQL 命令，用 Respone 返回结果
end;

procedure TdmInIOCPTest.InIOCPDataModuleWebSocketQuery(Sender: TObject; JSON: TBaseJSON; Result: TResultJSON);
begin
  // 执行 WebSocket 的操作
  FQuery.SQL.Text := 'SELECT * FROM tbl_xzqh';
  FQuery.Active := True;

  // A. 把数据集当作变量发送给客户端
  //    自动压缩，客户端自动解压
  Result.V['_data'] := DataSetProvider1.Data;
  Result.S['_table'] := 'tbl_xzqh';  // FQuery 要关闭，返回待更新数据表给客户端
  FQuery.Active := False;

  // 可以继续加入明细表
//  Result.V['_detail'] := DataSetProvider2.Data;
//  Result.S['_table2'] := 'tbl_details';

  // B. 如果用 FireDAC，可以把数据集保存到 JSON，
  //    用 Attachment 返回给客户端，如：
  // FQuery.SaveToFile('e:\aaa.json', sfJSON);
  // Result.Attachment := TFileStream.Create('e:\aaa.json', fmOpenRead);
  // Result.S['attach'] := 'query.dat';  //附件名称

  // C. 用以下方法返回不带描述信息的 JSON 给客户端：
  // Result.DataSet := FQuery;  // 发送完毕会自动关闭 FQuery
  
end;

procedure TdmInIOCPTest.InIOCPDataModuleWebSocketUpdates(Sender: TObject;
  JSON: TBaseJSON; Result: TResultJSON);
var
  ErrorCount: Integer;
begin
  if not FConnection.InTransaction then
    FConnection.BeginTrans;
  try
    try
      // _delta 是客户端传过来的变更数据
      DataSetProvider1.ApplyUpdates(JSON.V['_delta'], 0, ErrorCount);
    finally
      if ErrorCount = 0 then
        CommitTransaction
      else
      if FConnection.InTransaction then
        FConnection.RollbackTrans;
    end;
  except
    if FConnection.InTransaction then
      FConnection.RollbackTrans;
    Raise;    // 基类有异常处理，要 Raise
  end;
end;

end.
