unit MicrosoftPlanner;

interface

uses
  System.SysUtils,
  System.Classes,
  System.JSON,
  System.Net.HttpClient,
  System.Net.URLClient,
  System.StrUtils,
  System.NetEncoding,
  System.Generics.Collections,
  MicrosoftApiAuthenticator;

type
  TMsPlannerCategory = record
    Name: string;
    id: string;
    enabled: boolean;
  end;

  TMsPlannerCheckListItem = record
    Id: string;
    Title: string;
    IsChecked: boolean;
    LastModifiedBy: string;  // not implemented atm
    LastModifiedDateTime: string;
    OrderHint: string;
    IsDeleted: boolean;
    class operator Initialize (out Dest: TMsPlannerCheckListItem);
  end;

  TMsPlannerTaskDetails = record
    Description: string;
    PreviewType: string;
    Checklist: TArray<TMsPlannerCheckListItem>;
    ETag: string;
  end;

  TMsPlannerTask = record
    Id: string;
    Title: string;
    OrderHint: string;
    BucketId: string;
    PlanId: string;
    CreatedDateTime: string;
    CompletedDateTime: string;
    PercentComplete: string;
    DueDateTime: string;
    HasDescription: string;
    PreviewType: string;
    ETag: string;
    TaskDetails: TMsPlannerTaskDetails;
    AppliedCategories: TArray<TMsPlannerCategory>;
  end;

  TMsPlannerBucket = record
    Id: string;
    Name: string;
    OrderHint: string;
    PlanId: string;
    Tasks: TArray<TMsPlannerTask>;
    ETag: string;
  end;

  TMsPlannerPlanner = record
    Id: string;
    Title: string;
    Owner: string;
    CreatedDateTime: string;
    Buckets: TArray<TMsPlannerBucket>;
    ETag: string;
    Categories: TArray<TMsPlannerCategory>;
  end;

  TMsPlannerGroup = record
    Id: string;
    DisplayName: string;
    Description: string;
    CreatedDateTime: string;
    Planners: TArray<TMsPlannerPlanner>;
  end;

  TMsPlanner = class(TMsAdapter)
  private
    procedure handleError(AReq: IHttpRequest; ARes: IHTTPResponse);
    function buildUrl(s: string): string;

    function FExecuteRequest(AReq: IHttpRequest): IHTTPResponse;

    function GetValue(AJ: TJsonValue; AKey: string; var AValue: string): boolean;
  protected
  public
    function GetGroups: TArray<TMsPlannerGroup>;
    procedure GetGroup(var Group: TMsPlannerGroup);
    procedure GetPlanners(var Group: TMsPlannerGroup); overload;
    procedure GetPlanners(var Group: TMsPlannerGroup; details: boolean); overload;
    procedure GetPlanner(var Planner: TMsPlannerPlanner);
    procedure GetPlannerDetails(var Planner: TMsPlannerPlanner);
    procedure GetBuckets(var Planner: TMsPlannerPlanner);
    procedure GetBucket(var Bucket: TMsPlannerBucket);
    procedure GetTasks(var Bucket: TMsPlannerBucket); overload;
    procedure GetTasks(var Bucket: TMsPlannerBucket; details: Boolean); overload;
    procedure GetTask(var Task: TMsPlannerTask); overload;
    procedure GetTask(var Task: TMsPlannerTask; details: Boolean); overload;
    procedure GetTaskDetails(var Task: TMsPlannerTask);

    procedure CreateBucket(var Bucket: TMsPlannerBucket);
    procedure CreateTask(var Task: TMsPlannerTask);

    procedure UpdatePlannerDetails(var Planner: TMsPlannerPlanner);
    procedure UpdateBucket(var Bucket: TMsPlannerBucket);
    procedure UpdateTask(var Task: TMsPlannerTask);
    procedure UpdateTaskDetails(var Task: TMsPlannerTask);

    procedure DeleteBucket(var Bucket: TMsPlannerBucket);
    procedure DeleteTask(var Task: TMsPlannerTask);

    procedure MapCategories(Planner: TMsPlannerPlanner; var Task: TMsPlannerTask);

    constructor Create(Authenticator: TMsAuthenticator); reintroduce;
    destructor Destroy; override;
  end;

implementation

{ TMsPlannerCheckListItem }

class operator TMsPlannerCheckListItem.Initialize (out Dest: TMsPlannerCheckListItem);
begin
  Dest.Id := GUIDToString(TGUID.NewGuid).Replace('{', '').Replace('}', '');
  Dest.Title := '';
  Dest.IsChecked := False;
  Dest.LastModifiedBy := '';
  Dest.LastModifiedDateTime := '';
  Dest.OrderHint := ' !';
  Dest.IsDeleted := False;
end;

{ TMsPlanner }

constructor TMsPlanner.Create(Authenticator: TMsAuthenticator);
begin
  inherited Create(Authenticator);
end;

destructor TMsPlanner.Destroy;
begin

  inherited Destroy;
end;

function TMsPlanner.FExecuteRequest(AReq: IHttpRequest): IHTTPResponse;
var
  AStatusCode: integer;
  ARetryAfterStr: string;
  ARetryAfter: integer;
  ARetryCount: integer;
const
  DefaultRetryAfter = 1;
  Max_Retry = 10;

  function GetHeaderValue(AHeaderName: string; AHeaders: TNetHeaders; var AValue: string): boolean;
  var
    AHeader: TNetHeader;
  begin
    AValue := '';
    Result := False;
    for AHeader in AHeaders do
    begin
      if SameText(AHeader.Name, AHeaderName) then
      begin
        AValue := AHeader.Value;
        Result := True;
        Break;
      end;
    end;
  end;
begin
  AStatusCode := 429;
  ARetryAfter := 0;
  ARetryCount := 0;
  while (AStatusCode = 429) and (ARetryCount <= Max_Retry) do
  begin
    inc(ARetryCount);
    Result := self.Http.Execute(AReq);
    AStatusCode := Result.StatusCode;
    if AStatusCode = 429 then
    begin
      self.handleError(AReq, Result);
      if GetHeaderValue('Retry-After', Result.Headers, ARetryAfterStr) then
      if TryStrToInt(ARetryAfterStr, ARetryAfter) then
      begin
        Sleep(ARetryAfter * 1000);
      end
      else
      begin
        Sleep(1000 * DefaultRetryAfter);
      end
      else
      begin
        Sleep(1000 * DefaultRetryAfter);
      end;
    end;
  end;
end;

function TMsPlanner.GetValue(AJ: TJsonValue; AKey: string; var AValue: string): boolean;
var
  AI: Integer;
  AJsonObj: TJSONObject;
begin
  Result := False;
  AValue := '';
  if AKey <> '' then
  begin
    AJsonObj := AJ as TJSONObject;
    for AI := 0 to AJsonObj.Count - 1 do
    begin
      if AJsonObj.Pairs[AI].JsonString.Value = AKey then
      begin
        AValue :=AJsonObj.Pairs[AI].JsonValue.Value;
        Result := True;
        Break;
      end;
    end;
  end;
end;

procedure TMsPlanner.handleError(AReq: IHttpRequest; ARes: IHTTPResponse);
var
  AErr: TMsError;
  AJ: TJSONValue;
  AJErr: TJSONValue;
begin
  AErr.HTTPStatusCode := ARes.StatusCode;
  AErr.HTTPStatusText := ARes.StatusText;
  AErr.HTTPurl := AReq.URL.ToString;
  AErr.HTTPMethod := AReq.MethodString;
  AErr.HTTPreq_Header := AReq.Headers;
  AErr.HTTPres_header := ARes.Headers;
  AErr.HTTPerror_data := ARes.ContentAsString;

  Aj := TJSONValue.ParseJSONValue(ARes.ContentAsString(TEncoding.UTF8));
  if Aj <> nil then
  begin
    if Aj.TryGetValue<TJsonValue>('error', AJErr) then
    begin
      AJErr.TryGetValue<string>('code', AErr.HTTPerror_name);
      AJErr.TryGetValue<string>('message', AErr.HTTPerror_description);
    end;
    Aj.Free;
  end;
  self.OnRequestError(AErr);
end;

function TMsPlanner.buildUrl(s: string): string;
begin
  Result := 'https://graph.microsoft.com/v1.0/' + s;
end;

function TMsPlanner.GetGroups: TArray<TMsPlannerGroup>;
var
  // requests
  AReq: IHttpRequest;
  ARes: IHTTPResponse;

  // group data
  AJ: TJSONValue;
  AJArr: TJSONArray;
  AJVal: TJSONValue;
  i: integer;
  Group: TMsPlannerGroup;
begin
  AReq := self.Http.GetRequest(sHTTPMethodGet, self.buildUrl('me/transitiveMemberOf/microsoft.graph.group?$count=true&$select=displayName,id,createdDateTime,description'));
  AReq.AddHeader('Content-Type', 'application/json');
  AReq.AddHeader('Accept', 'application/json');
  AReq.AddHeader('Authorization', self.Token);

  ARes := self.FExecuteRequest(AReq);

  if ARes.StatusCode = 200 then
  begin
    AJ := TJSONValue.ParseJSONValue(ARes.ContentAsString(TEncoding.UTF8));
    if AJ <> nil then
    begin
      if AJ.TryGetValue<TJSONArray>('value', AJArr) then
      begin
        SetLength(Result, AJArr.Count);
        for i := 0 to AJArr.Count - 1 do
        begin
          AJVal := AJArr.Items[i];
          AJVal.TryGetValue<string>('id', Group.Id);
          AJVal.TryGetValue<string>('displayName', Group.DisplayName);
          AJVal.TryGetValue<string>('description', Group.Description);
          AJVal.TryGetValue<string>('createdDateTime', Group.CreatedDateTime);
          Result[i] := Group;
        end;
      end;
      AJ.Free;
    end;
  end
  else
  begin
    self.handleError(AReq, ARes);
  end;
end;

procedure TMsPlanner.GetGroup(var Group: TMsPlannerGroup);
var
  // requests
  AReq: IHttpRequest;
  ARes: IHTTPResponse;

  // group data
  AJ: TJSONValue;
begin
  AReq := self.Http.GetRequest(sHTTPMethodGet, self.buildUrl('groups/' + Group.Id + '?$count=true&$select=id,displayName,description,createdDateTime'));
  AReq.AddHeader('Content-Type', 'application/json');
  AReq.AddHeader('Accept', 'application/json');
  AReq.AddHeader('Authorization', self.Token);
  ARes := self.FExecuteRequest(AReq);

  if ARes.StatusCode = 200 then
  begin
    AJ := TJSONValue.ParseJSONValue(ARes.ContentAsString(TEncoding.UTF8));
    if AJ <> nil then
    begin
      AJ.TryGetValue<string>('id', Group.Id);
      AJ.TryGetValue<string>('displayName', Group.DisplayName);
      AJ.TryGetValue<string>('description', Group.Description);
      AJ.TryGetValue<string>('createdDateTime', Group.CreatedDateTime);
      AJ.Free;
    end;
  end
  else
  begin
    self.handleError(AReq, ARes);
  end;
end;

procedure TMsPlanner.GetPlanners(var Group: TMsPlannerGroup);
var
  // requests
  AReq: IHttpRequest;
  ARes: IHTTPResponse;

  // planner data
  AJ: TJSONValue;
  AJArr: TJSONArray;
  AJVal: TJSONValue;
  i: integer;
  Planner: TMsPlannerPlanner;
begin
  AReq := self.Http.GetRequest(sHTTPMethodGet, self.buildUrl('groups/' + Group.Id + '/planner/plans?$count=true&$select=id,title,owner,createdDateTime'));
  AReq.AddHeader('Content-Type', 'application/json');
  AReq.AddHeader('Accept', 'application/json');
  AReq.AddHeader('Authorization', self.Token);
  ARes := self.FExecuteRequest(AReq);

  if ARes.StatusCode = 200 then
  begin
    AJ := TJSONValue.ParseJSONValue(ARes.ContentAsString(TEncoding.UTF8));
    if AJ <> nil then
    begin
      if AJ.TryGetValue<TJSONArray>('value', AJArr) then
      begin
        SetLength(Group.Planners, AJArr.Count);
        for i := 0 to AJArr.Count - 1 do
        begin
          AJVal := AJArr.Items[i];
          AJVal.TryGetValue<string>('id', Planner.Id);
          AJVal.TryGetValue<string>('title', Planner.Title);
          AJVal.TryGetValue<string>('owner', Planner.Owner);
          AJVal.TryGetValue<string>('createdDateTime', Planner.CreatedDateTime);
          self.GetValue(AJVal, '@odata.etag', Planner.ETag);
          Group.Planners[i] := Planner;
        end;
      end;
      AJ.Free;
    end;
  end
  else
  begin
    self.handleError(AReq, ARes);
  end;
end;

procedure TMsPlanner.GetPlanners(var Group: TMsPlannerGroup; details: boolean);
var
  AI: integer;
  APlanner: TMsPlannerPlanner;
begin
  self.GetPlanners(Group);
  if details then
  begin
    for AI := 0 to length(Group.Planners)-1 do
    begin
      APlanner := Group.Planners[AI];
      self.GetPlannerDetails(APlanner);
      Group.Planners[AI] := APlanner;
    end;
  end;
end;

procedure TMsPlanner.GetPlanner(var Planner: TMsPlannerPlanner);
var
  // requests
  AReq: IHttpRequest;
  ARes: IHTTPResponse;

  // planner data
  AJ: TJSONValue;
begin
  AReq := self.Http.GetRequest(sHTTPMethodGet, self.buildUrl('planner/plans/' + Planner.Id + '?$count=true&$select=id,title,owner,createdDateTime'));
  AReq.AddHeader('Content-Type', 'application/json');
  AReq.AddHeader('Accept', 'application/json');
  AReq.AddHeader('Authorization', self.Token);
  ARes := self.FExecuteRequest(AReq);

  if ARes.StatusCode = 200 then
  begin
    AJ := TJSONValue.ParseJSONValue(ARes.ContentAsString(TEncoding.UTF8));
    if AJ <> nil then
    begin
      AJ.TryGetValue<string>('id', Planner.Id);
      AJ.TryGetValue<string>('title', Planner.Title);
      AJ.TryGetValue<string>('owner', Planner.Owner);
      AJ.TryGetValue<string>('createdDateTime', Planner.CreatedDateTime);
      self.GetValue(AJ, '@odata.etag', Planner.ETag);
      AJ.Free;
    end;
  end
  else
  begin
    self.handleError(AReq, ARes);
  end;
end;

procedure TMsPlanner.GetPlannerDetails(var Planner: TMsPlannerPlanner);
var
  // requests
  AReq: IHttpRequest;
  ARes: IHTTPResponse;

  // planner data
  AJ: TJSONValue;
  AJsonCategories: TJSONObject;
  ANewCategory: TMsPlannerCategory;
  AI: integer;
begin
  AReq := self.Http.GetRequest(sHTTPMethodGet, self.buildUrl('planner/plans/' + Planner.Id + '/details'));
  AReq.AddHeader('Content-Type', 'application/json');
  AReq.AddHeader('Accept', 'application/json');
  AReq.AddHeader('Authorization', self.Token);
  ARes := self.FExecuteRequest(AReq);

  if ARes.StatusCode = 200 then
  begin
    AJ := TJSONValue.ParseJSONValue(ARes.ContentAsString(TEncoding.UTF8));
    if AJ <> nil then
    begin
      if AJ.TryGetValue<TJsonObject>('categoryDescriptions', AJsonCategories) then
      begin
        for AI := 0 to AJsonCategories.Count - 1 do
        begin
          ANewCategory.id := AJsonCategories.Pairs[AI].JsonString.Value;
          ANewCategory.name := AJsonCategories.Pairs[AI].JsonValue.Value;
          Planner.Categories := Planner.Categories + [ANewCategory];
        end;
      end;

      AJ.Free;
    end;
  end
  else
  begin
    self.handleError(AReq, ARes);
  end;
end;

procedure TMsPlanner.GetBuckets(var Planner: TMsPlannerPlanner);
var
  // requests
  AReq: IHttpRequest;
  ARes: IHTTPResponse;

  // bucket data
  AJ: TJSONValue;
  AJArr: TJSONArray;
  AJVal: TJSONValue;
  i: integer;
  Bucket: TMsPlannerBucket;
begin
  AReq := self.Http.GetRequest(sHTTPMethodGet, self.buildUrl('planner/plans/' + Planner.Id + '/buckets?$count=true&$select=id,name,orderHint,planId'));
  AReq.AddHeader('Content-Type', 'application/json');
  AReq.AddHeader('Accept', 'application/json');
  AReq.AddHeader('Authorization', self.Token);
  ARes := self.FExecuteRequest(AReq);

  if ARes.StatusCode = 200 then
  begin
    AJ := TJSONValue.ParseJSONValue(ARes.ContentAsString(TEncoding.UTF8));
    if AJ <> nil then
    begin
      if AJ.TryGetValue<TJSONArray>('value', AJArr) then
      begin
        SetLength(Planner.Buckets, AJArr.Count);
        for i := 0 to AJArr.Count - 1 do
        begin
          AJVal := AJArr.Items[i];
          AJVal.TryGetValue<string>('id', Bucket.Id);
          AJVal.TryGetValue<string>('name', Bucket.Name);
          AJVal.TryGetValue<string>('orderHint', Bucket.OrderHint);
          AJVal.TryGetValue<string>('planId', Bucket.PlanId);
          self.GetValue(AJVal, '@odata.etag', Bucket.ETag);
          Planner.Buckets[i] := Bucket;
        end;
      end;
      AJ.Free;
    end;
  end
  else
  begin
    self.handleError(AReq, ARes);
  end;
end;

procedure TMsPlanner.GetBucket(var Bucket: TMsPlannerBucket);
var
  // requests
  AReq: IHttpRequest;
  ARes: IHTTPResponse;

  // bucket data
  AJ: TJSONValue;
begin
  AReq := self.Http.GetRequest(sHTTPMethodGet, self.buildUrl('planner/buckets/' + Bucket.Id + '?$count=true&$select=id,name,orderHint,planId'));
  AReq.AddHeader('Content-Type', 'application/json');
  AReq.AddHeader('Accept', 'application/json');
  AReq.AddHeader('Authorization', self.Token);
  ARes := self.FExecuteRequest(AReq);

  if ARes.StatusCode = 200 then
  begin
    AJ := TJSONValue.ParseJSONValue(ARes.ContentAsString(TEncoding.UTF8));
    if AJ <> nil then
    begin
      AJ.TryGetValue<string>('id', Bucket.Id);
      AJ.TryGetValue<string>('name', Bucket.Name);
      AJ.TryGetValue<string>('orderHint', Bucket.OrderHint);
      AJ.TryGetValue<string>('planId', Bucket.PlanId);
      self.GetValue(AJ, '@odata.etag', Bucket.ETag);
      AJ.Free;
    end;
  end
  else
  begin
    self.handleError(AReq, ARes);
  end;
end;

procedure TMsPlanner.GetTasks(var Bucket: TMsPlannerBucket);
var
  // requests
  AReq: IHttpRequest;
  ARes: IHTTPResponse;

  // task data
  AJ: TJSONValue;
  AJArr: TJSONArray;
  AJVal: TJSONValue;
  AJAppliedCategories: TJSONObject;
  i: integer;
  AI: integer;
  Task: TMsPlannerTask;
  ANewAppliedCategory: TMsPlannerCategory;
begin
  AReq := self.Http.GetRequest(sHTTPMethodGet, self.buildUrl('planner/buckets/' + Bucket.Id + '/tasks?$count=true&$select=id,title,orderHint,planId,createdDateTime,completedDateTime,percentComplete,dueDateTime,hasDescription,previewType,appliedCategories'));
  AReq.AddHeader('Content-Type', 'application/json');
  AReq.AddHeader('Accept', 'application/json');
  AReq.AddHeader('Authorization', self.Token);
  ARes := self.FExecuteRequest(AReq);

  if ARes.StatusCode = 200 then
  begin
    AJ := TJSONValue.ParseJSONValue(ARes.ContentAsString(TEncoding.UTF8));
    if AJ <> nil then
    begin
      if AJ.TryGetValue<TJSONArray>('value', AJArr) then
      begin
        SetLength(Bucket.Tasks, AJArr.Count);
        for i := 0 to AJArr.Count - 1 do
        begin
          AJVal := AJArr.Items[i];
          AJVal.TryGetValue<string>('id', Task.Id);
          AJVal.TryGetValue<string>('title', Task.Title);
          AJVal.TryGetValue<string>('orderHint', Task.OrderHint);

          AJVal.TryGetValue<string>('planId', Task.PlanId);
          AJVal.TryGetValue<string>('createdDateTime', Task.CreatedDateTime);
          AJVal.TryGetValue<string>('completedDateTime', Task.CompletedDateTime);
          AJVal.TryGetValue<string>('percentComplete', Task.PercentComplete);
          AJVal.TryGetValue<string>('dueDateTime', Task.DueDateTime);
          AJVal.TryGetValue<string>('hasDescription', Task.HasDescription);
          AJVal.TryGetValue<string>('previewType', Task.PreviewType);

          // get appliedCategories
          if AJVal.TryGetValue<TJSONObject>('appliedCategories', AJAppliedCategories) then
          begin
            for AI := 0 to AJAppliedCategories.Count - 1 do
            begin
              ANewAppliedCategory.id := AJAppliedCategories.Pairs[AI].JsonString.Value;
              ANewAppliedCategory.enabled := AJAppliedCategories.Pairs[AI].JsonValue.Value = 'true';
              Task.AppliedCategories := Task.AppliedCategories + [ANewAppliedCategory];
            end;
          end;

          self.GetValue(AJVal, '@odata.etag', Task.ETag);
          Bucket.Tasks[i] := Task;
        end;
      end;
      AJ.Free;
    end;
  end
  else
  begin
    self.handleError(AReq, ARes);
  end;
end;

procedure TMsPlanner.GetTasks(var Bucket: TMsPlannerBucket; details: boolean);
var
  AI: integer;
begin
  self.GetTasks(Bucket);
  if details then
    for AI := 0 to Length(Bucket.Tasks) - 1 do
      self.GetTaskDetails(Bucket.Tasks[AI]);
end;

procedure TMsPlanner.GetTask(var Task: TMsPlannerTask);
var
  // requests
  AReq: IHttpRequest;
  ARes: IHTTPResponse;

  // task data
  AJ: TJSONValue;
  AJAppliedCategories: TJSONObject;
  ANewAppliedCategory: TMsPlannerCategory;
  i: integer;
begin
  AReq := self.Http.GetRequest(sHTTPMethodGet, self.buildUrl('planner/tasks/' + Task.Id));
  AReq.AddHeader('Content-Type', 'application/json');
  AReq.AddHeader('Accept', 'application/json');
  AReq.AddHeader('Authorization', self.Token);
  ARes := self.FExecuteRequest(AReq);

  if ARes.StatusCode = 200 then
  begin
    AJ := TJSONValue.ParseJSONValue(ARes.ContentAsString(TEncoding.UTF8));
    if AJ <> nil then
    begin
      AJ.TryGetValue<string>('id', Task.Id);
      AJ.TryGetValue<string>('title', Task.Title);
      AJ.TryGetValue<string>('orderHint', Task.OrderHint);
      AJ.TryGetValue<string>('bucketId', Task.BucketId);
      AJ.TryGetValue<string>('planId', Task.PlanId);
      AJ.TryGetValue<string>('createdDateTime', Task.CreatedDateTime);
      AJ.TryGetValue<string>('completedDateTime', Task.CompletedDateTime);
      AJ.TryGetValue<string>('percentComplete', Task.PercentComplete);
      AJ.TryGetValue<string>('dueDateTime', Task.DueDateTime);
      AJ.TryGetValue<string>('hasDescription', Task.HasDescription);
      AJ.TryGetValue<string>('previewType', Task.PreviewType);

      // get appliedCategories
      if AJ.TryGetValue<TJSONObject>('appliedCategories', AJAppliedCategories) then
      begin
        for i := 0 to AJAppliedCategories.Count - 1 do
        begin
          ANewAppliedCategory.id := AJAppliedCategories.Pairs[i].JsonString.Value;
          ANewAppliedCategory.enabled := AJAppliedCategories.Pairs[i].JsonValue.Value = 'true';
          Task.AppliedCategories := Task.AppliedCategories + [ANewAppliedCategory];
        end;
      end;

      self.GetValue(AJ, '@odata.etag', Task.ETag);
      AJ.Free;
    end;
  end
  else
  begin
    self.handleError(AReq, ARes);
  end;
end;

procedure TMsPlanner.GetTask(var Task: TMsPlannerTask; details: boolean);
begin
  self.GetTask(Task);
  if details then
  begin
    self.GetTaskDetails(Task);
  end;
end;

procedure TMsPlanner.GetTaskDetails(var Task: TMsPlannerTask);
var
  // requests
  AReq: IHttpRequest;
  ARes: IHTTPResponse;

  // task data
  AJ: TJSONValue;
  AJObj: TJSONObject;
  AJChecklistItem: TJSONValue;
  ANewChecklistItem: TMsPlannerCheckListItem;
  AStr: string;
  Ai: Integer;
begin
  AReq := self.Http.GetRequest(sHTTPMethodGet, self.buildUrl('planner/tasks/' + Task.Id + '/details'));
  AReq.AddHeader('Content-Type', 'application/json');
  AReq.AddHeader('Accept', 'application/json');
  AReq.AddHeader('Authorization', self.Token);
  ARes := self.FExecuteRequest(AReq);

  if ARes.StatusCode = 200 then
  begin
    AJ := TJSONValue.ParseJSONValue(ARes.ContentAsString(TEncoding.UTF8));
    if AJ <> nil then
    begin
      AJ.TryGetValue<string>('description', Task.TaskDetails.Description);
      AJ.TryGetValue<string>('previewType', Task.TaskDetails.PreviewType);

      // get Checklist
      if AJ.TryGetValue<TJSONObject>('checklist', AJObj) then
      begin
        for Ai := 0 to AJObj.Count - 1 do
        begin
          ANewChecklistItem.id := AJObj.Pairs[Ai].JsonString.Value;
          AJChecklistItem := AJObj.Pairs[Ai].JsonValue;
          if AJChecklistItem.TryGetValue<string>('isChecked', AStr) then
            ANewChecklistItem.IsChecked := AStr = 'true';
          AJChecklistItem.TryGetValue<string>('title', ANewChecklistItem.Title);
          AJChecklistItem.TryGetValue<string>('lastModifiedByDateTime', ANewChecklistItem.LastModifiedDateTime);
          AJChecklistItem.TryGetValue<string>('orderHint', ANewChecklistItem.OrderHint);
          Task.TaskDetails.Checklist := Task.TaskDetails.Checklist + [ANewChecklistItem];
        end;
        self.GetValue(AJ, '@odata.etag', Task.TaskDetails.ETag);
      end;
      AJ.Free;
    end;
  end
  else
  begin
    self.handleError(AReq, ARes);
  end;
end;


procedure TMsPlanner.UpdatePlannerDetails(var Planner: TMsPlannerPlanner);
var
  // requests
  AReq: IHttpRequest;
  ARes: IHTTPResponse;
  APayload: TStringStream;

  // planner data
  AJ: TJSONValue;
  AJObj: TJSONObject;
  AJsonCategories: TJSONObject;
  ANewCategory: TMsPlannerCategory;
  Ai: Integer;
begin
  AJObj := TJSONObject.Create;
  if length(Planner.Categories) > 0 then
  begin
    AJsonCategories := TJSONObject.Create;
    for Ai := 0 to Length(Planner.Categories) - 1 do
    begin
      AJsonCategories.AddPair(Planner.Categories[Ai].Name, Planner.Categories[Ai].Name);
    end;
    AJObj.AddPair('categoryDescriptions', AJsonCategories);
  end;

  AReq := self.Http.GetRequest(sHTTPMethodPatch, self.buildUrl('planner/plans/' + Planner.Id + '/details'));
  AReq.AddHeader('Content-Type', 'application/json');
  AReq.AddHeader('Accept', 'application/json');
  AReq.AddHeader('Authorization', self.Token);
  AReq.AddHeader('Prefer', 'return=representation');
  APayload := TStringStream.Create(AJObj.ToJSON);
  AJObj.Free;
  AReq.SourceStream := APayload;
  ARes := self.FExecuteRequest(AReq);
  APayload.Free;

  if ARes.StatusCode = 200 then
  begin
    AJ := TJSONValue.ParseJSONValue(ARes.ContentAsString(TEncoding.UTF8));
    if AJ <> nil then
    begin
      if AJ.TryGetValue<TJsonObject>('categoryDescriptions', AJsonCategories) then
      begin
        for AI := 0 to AJsonCategories.Count - 1 do
        begin
          ANewCategory.id := AJsonCategories.Pairs[AI].JsonString.Value;
          ANewCategory.name := AJsonCategories.Pairs[AI].JsonValue.Value;
          Planner.Categories := Planner.Categories + [ANewCategory];
        end;
      end;
      AJ.Free;
    end;
  end
  else
  begin
    self.handleError(AReq, ARes);
  end;
end;


procedure TMsPlanner.CreateTask(var Task: TMsPlannerTask);
var
  bucket: TMsPlannerBucket;

  // requests
  AReq: IHttpRequest;
  ARes: IHTTPResponse;
  APayload: TStringStream;

  // task data
  AJ: TJSONValue;
  AJObj: TJSONObject;
  AJAppliedCategories: TJSONObject;
  ANewAppliedCategory: TMsPlannerCategory;
  i: Integer;
begin
  AJObj := TJSONObject.Create;

  if task.PlanId = '' then
  begin
    bucket.Id := Task.BucketId;
    self.GetBucket(bucket);
    Task.PlanId := bucket.PlanId;
  end;

  AJObj.AddPair('title', Task.Title);
  if Task.OrderHint <> '' then
    AJObj.AddPair('orderHint', Task.OrderHint);
  AJObj.AddPair('bucketId', Task.BucketId);
  AJObj.AddPair('planId', Task.PlanId);
  if Task.PercentComplete <> '' then
    AJObj.AddPair('percentComplete', Task.PercentComplete);
  if Task.DueDateTime <> '' then
    AJObj.AddPair('dueDateTime', Task.DueDateTime);
  
  // add appliedCategories
  if Length(Task.AppliedCategories) > 0 then
  begin
    AJAppliedCategories := TJSONObject.Create;
    for i := 0 to Length(Task.AppliedCategories) - 1 do
    begin
      AJAppliedCategories.AddPair(Task.AppliedCategories[i].id, TJSONBool.Create(Task.AppliedCategories[i].enabled));
    end;
    AJObj.AddPair('appliedCategories', AJAppliedCategories);
  end;

  AReq := self.Http.GetRequest(sHTTPMethodPost, self.buildUrl('planner/tasks'));
  AReq.AddHeader('Content-Type', 'application/json');
  AReq.AddHeader('Accept', 'application/json');
  AReq.AddHeader('Authorization', self.Token);
  APayload := TStringStream.Create(AJObj.ToJSON);
  AJObj.Free;
  AReq.SourceStream := APayload;
  ARes := self.FExecuteRequest(AReq);
  APayload.Free;

  if ARes.StatusCode = 201 then
  begin
    AJ := TJSONValue.ParseJSONValue(ARes.ContentAsString(TEncoding.UTF8));
    if AJ <> nil then
    begin
      AJ.TryGetValue<string>('id', Task.Id);
      AJ.TryGetValue<string>('title', Task.Title);
      AJ.TryGetValue<string>('orderHint', Task.OrderHint);
      AJ.TryGetValue<string>('planId', Task.PlanId);
      AJ.TryGetValue<string>('createdDateTime', Task.CreatedDateTime);
      AJ.TryGetValue<string>('completedDateTime', Task.CompletedDateTime);
      AJ.TryGetValue<string>('percentComplete', Task.PercentComplete);
      AJ.TryGetValue<string>('dueDateTime', Task.DueDateTime);
      AJ.TryGetValue<string>('hasDescription', Task.HasDescription);
      AJ.TryGetValue<string>('previewType', Task.PreviewType);

      // get appliedCategories
      Task.AppliedCategories := [];
      if AJ.TryGetValue<TJSONObject>('appliedCategories', AJAppliedCategories) then
      begin
        for i := 0 to AJAppliedCategories.Count - 1 do
        begin
          ANewAppliedCategory.Name := AJAppliedCategories.Pairs[i].JsonString.Value;
          ANewAppliedCategory.enabled := AJAppliedCategories.Pairs[i].JsonValue.Value = 'true';
          Task.AppliedCategories := Task.AppliedCategories + [ANewAppliedCategory];
        end;
      end;

      self.GetValue(AJ, '@odata.etag', Task.ETag);
      AJ.Free;
    end;
  end
  else
  begin
    self.handleError(AReq, ARes);
  end;
end;

procedure TMsPlanner.UpdateTask(var Task: TMsPlannerTask);
var
  OldTask: TMsPlannerTask;
  // requests
  AReq: IHttpRequest;
  ARes: IHTTPResponse;
  APayload: TStringStream;

  // task data
  AJ: TJSONValue;
  AJObj: TJSONObject;
  AJAppliedCategories: TJSONObject;
  ANewAppliedCategory: TMsPlannerCategory;
  i: Integer;
begin
  if Task.ETag = '' then
  begin
    OldTask.Id := Task.Id;
    self.GetTask(OldTask);
    Task.ETag := OldTask.ETag;
  end;

  AJObj := TJSONObject.Create;
  if Task.Title <> '' then
    AJObj.AddPair('title', Task.Title);
  if Task.OrderHint <> '' then
    AJObj.AddPair('orderHint', Task.OrderHint);
  if Task.BucketId <> '' then
    AJObj.AddPair('bucketId', Task.BucketId);
  if Task.PercentComplete <> '' then
    AJObj.AddPair('percentComplete', Task.PercentComplete);
  if Task.DueDateTime <> '' then
    AJObj.AddPair('dueDateTime', Task.DueDateTime);
  if length(Task.AppliedCategories) > 0 then
  begin
    AJAppliedCategories := TJSONObject.Create;
    for i := 0 to Length(Task.AppliedCategories) - 1 do
    begin
      AJAppliedCategories.AddPair(Task.AppliedCategories[i].id, TJSONBool.Create(Task.AppliedCategories[i].enabled));
    end;
    AJObj.AddPair('categories', AJAppliedCategories);
  end;

  AReq := self.Http.GetRequest(sHTTPMethodPatch, self.buildUrl('planner/tasks/' + Task.Id));
  AReq.AddHeader('Content-Type', 'application/json');
  AReq.AddHeader('Accept', 'application/json');
  AReq.AddHeader('Authorization', self.Token);
  AReq.AddHeader('Prefer', 'return=representation');
  AReq.AddHeader('If-Match', Task.ETag);
  APayload := TStringStream.Create(AJObj.ToJSON);
  AJObj.Free;
  AReq.SourceStream := APayload;
  ARes := self.FExecuteRequest(AReq);
  APayload.Free;

  if ARes.StatusCode = 200 then
  begin
    AJ := TJSONValue.ParseJSONValue(ARes.ContentAsString(TEncoding.UTF8));
    if AJ <> nil then
    begin
      AJ.TryGetValue<string>('id', Task.Id);
      AJ.TryGetValue<string>('title', Task.Title);
      AJ.TryGetValue<string>('orderHint', Task.OrderHint);
      AJ.TryGetValue<string>('bucketId', Task.BucketId);
      AJ.TryGetValue<string>('planId', Task.PlanId);
      AJ.TryGetValue<string>('createdDateTime', Task.CreatedDateTime);
      AJ.TryGetValue<string>('completedDateTime', Task.CompletedDateTime);
      AJ.TryGetValue<string>('percentComplete', Task.PercentComplete);
      AJ.TryGetValue<string>('dueDateTime', Task.DueDateTime);
      AJ.TryGetValue<string>('hasDescription', Task.HasDescription);
      AJ.TryGetValue<string>('previewType', Task.PreviewType);

      // get appliedCategories
      if AJ.TryGetValue<TJSONObject>('appliedCategories', AJAppliedCategories) then
      begin
        SetLength(Task.AppliedCategories, AJAppliedCategories.Count);
        for i := 0 to AJAppliedCategories.Count - 1 do
        begin
          ANewAppliedCategory.Name := AJAppliedCategories.Pairs[i].JsonString.Value;
          ANewAppliedCategory.enabled := AJAppliedCategories.Pairs[i].JsonValue.Value = 'true';
          Task.AppliedCategories := Task.AppliedCategories + [ANewAppliedCategory];
        end;
      end;

      self.GetValue(AJ, '@odata.etag', Task.ETag);
      AJ.Free;
    end;
  end
  else
  begin
    self.handleError(AReq, ARes);
  end;
end;

procedure TMsPlanner.UpdateTaskDetails(var Task: TMsPlannerTask);
var
  OldTask: TMsPlannerTask;
  // requests
  AReq: IHttpRequest;
  ARes: IHTTPResponse;
  APayload: TStringStream;

  // task data
  AJ: TJSONValue;
  AJObj: TJSONObject;
  AJChecklist: TJSONObject;
  AJChecklistItem: TJSONObject;
  i: Integer;
begin
  if task.TaskDetails.ETag = '' then
  begin
    OldTask.Id := Task.Id;
    self.GetTaskDetails(OldTask);
    Task.TaskDetails.ETag := OldTask.TaskDetails.ETag;
  end;

  AJObj := TJSONObject.Create;
  if Task.TaskDetails.Description <> '' then
    AJObj.AddPair('description', Task.TaskDetails.Description);
  if Task.TaskDetails.PreviewType <> '' then
    AJObj.AddPair('previewType', Task.TaskDetails.PreviewType);
  if length(Task.TaskDetails.Checklist) > 0 then
  begin
    AJChecklist := TJSONObject.Create;
    for i := 0 to Length(Task.TaskDetails.Checklist) - 1 do
    begin
      if Task.TaskDetails.Checklist[i].Id <> '' then
      begin
        if Task.TaskDetails.Checklist[i].IsDeleted then
          AJChecklist.AddPair(Task.TaskDetails.Checklist[i].Id, TJSONNull.Create)
        else
        begin
          AJChecklistItem := TJSONObject.Create;
          AJChecklistItem.AddPair('title', Task.TaskDetails.Checklist[i].Title);
          AJChecklistItem.AddPair('isChecked', TJSONBool.Create(Task.TaskDetails.Checklist[i].IsChecked));
          AJChecklistItem.AddPair('orderHint', Task.TaskDetails.Checklist[i].OrderHint);
          AJChecklistItem.AddPair('@odata.type', TJSONString.Create('microsoft.graph.plannerChecklistItem'));
          AJChecklist.AddPair(Task.TaskDetails.Checklist[i].Id, AJChecklistItem);
        end;
      end;
    end;
    AJObj.AddPair('checklist', AJChecklist);
  end;

  AReq := self.Http.GetRequest(sHTTPMethodPatch, self.buildUrl('planner/tasks/' + Task.Id + '/details'));
  AReq.AddHeader('Content-Type', 'application/json');
  AReq.AddHeader('Accept', 'application/json');
  AReq.AddHeader('Authorization', self.Token);
  AReq.AddHeader('Prefer', 'return=representation');
  AReq.AddHeader('If-Match', Task.TaskDetails.ETag);
  APayload := TStringStream.Create(AJObj.ToJSON);
  AJObj.Free;
  AReq.SourceStream := APayload;
  ARes := self.FExecuteRequest(AReq);
  APayload.Free;

  if ARes.StatusCode = 200 then
  begin
    AJ := TJSONValue.ParseJSONValue(ARes.ContentAsString(TEncoding.UTF8));
    if AJ <> nil then
    begin
      AJ.TryGetValue<string>('description', Task.TaskDetails.Description);
      AJ.TryGetValue<string>('previewType', Task.TaskDetails.PreviewType);

      // get checklist
      if AJ.TryGetValue<TJSONObject>('checklist', AJChecklist) then
      begin
        SetLength(Task.TaskDetails.Checklist, AJChecklist.Count);
        for i := 0 to AJChecklist.Count - 1 do
        begin
          Task.TaskDetails.Checklist[i].Id := AJChecklist.Pairs[i].JsonString.Value;
          if AJChecklist.Pairs[i].JsonValue is TJSONNull then
            Task.TaskDetails.Checklist[i].IsDeleted := true
          else
          begin
            Task.TaskDetails.Checklist[i].IsDeleted := false;
            AJChecklist.Pairs[i].JsonValue.TryGetValue<string>('title', Task.TaskDetails.Checklist[i].Title);
            Task.TaskDetails.Checklist[i].IsChecked := AJChecklist.GetValue<string>('isChecked', 'false') = 'true';
            AJChecklist.Pairs[i].JsonValue.TryGetValue<string>('orderHint', Task.TaskDetails.Checklist[i].OrderHint);
          end;
        end;
      end;
      self.GetValue(AJ, '@odata.etag', Task.TaskDetails.ETag);
      AJ.Free;
    end;
  end
  else
  begin
    self.handleError(AReq, ARes);
  end;
end;


procedure TMsPlanner.DeleteTask(var Task: TMsPlannerTask);
var
  // requests
  AReq: IHttpRequest;
  ARes: IHTTPResponse;
begin
  if Task.ETag = '' then
  begin
    self.GetTask(Task);
  end;

  AReq := self.Http.GetRequest(sHTTPMethodDelete, self.buildUrl('planner/tasks/' + Task.Id));
  AReq.AddHeader('Content-Type', 'application/json');
  AReq.AddHeader('Accept', 'application/json');
  AReq.AddHeader('Authorization', self.Token);
  AReq.AddHeader('If-Match', Task.ETag);
  ARes := self.FExecuteRequest(AReq);

  if ARes.StatusCode = 204 then
  begin
    Task.Id := '';
  end
  else
  begin
    self.handleError(AReq, ARes);
  end;
end;

procedure TMsPlanner.CreateBucket(var Bucket: TMsPlannerBucket);
var
  // requests
  AReq: IHttpRequest;
  ARes: IHTTPResponse;
  APayload: TStringStream;

  // bucket data
  AJ: TJSONValue;
  AJObj: TJSONObject;
begin
  AJObj := TJSONObject.Create;
  AJObj.AddPair('name', Bucket.Name);
  AJObj.AddPair('planId', Bucket.PlanId);
  if Bucket.OrderHint <> '' then
    AJObj.AddPair('orderHint', Bucket.OrderHint);

  AReq := self.Http.GetRequest(sHTTPMethodPost, self.buildUrl('planner/buckets'));
  AReq.AddHeader('Content-Type', 'application/json');
  AReq.AddHeader('Accept', 'application/json');
  AReq.AddHeader('Authorization', self.Token);
  APayload := TStringStream.Create(AJObj.ToJSON);
  AJObj.Free;
  AReq.SourceStream := APayload;
  ARes := self.FExecuteRequest(AReq);
  APayload.Free;

  if ARes.StatusCode = 201 then
  begin
    AJ := TJSONValue.ParseJSONValue(ARes.ContentAsString(TEncoding.UTF8));
    if AJ <> nil then
    begin
      AJ.TryGetValue<string>('id', Bucket.Id);
      AJ.TryGetValue<string>('name', Bucket.Name);
      AJ.TryGetValue<string>('planId', Bucket.PlanId);
      AJ.TryGetValue<string>('orderHint', Bucket.OrderHint);
      self.GetValue(AJ, '@odata.etag', Bucket.ETag);
      AJ.Free;
    end;
  end
  else
  begin
    self.handleError(AReq, ARes);
  end;
end;

procedure TMsPlanner.UpdateBucket(var Bucket: TMsPlannerBucket);
var
  OldBucket: TMsPlannerBucket;
  // requests
  AReq: IHttpRequest;
  ARes: IHTTPResponse;
  APayload: TStringStream;

  // bucket data
  AJ: TJSONValue;
  AJObj: TJSONObject;
begin
  if Bucket.ETag = '' then
  begin
    OldBucket.id := Bucket.Id;
    self.GetBucket(OldBucket);
    Bucket.ETag := OldBucket.ETag;
  end;

  AJObj := TJSONObject.Create;
  if Bucket.Name <> '' then
    AJObj.AddPair('name', Bucket.Name);
  if Bucket.OrderHint <> '' then
    AJObj.AddPair('orderHint', Bucket.OrderHint);

  AReq := self.Http.GetRequest(sHTTPMethodPatch, self.buildUrl('planner/buckets/' + Bucket.Id));
  AReq.AddHeader('Content-Type', 'application/json');
  AReq.AddHeader('Accept', 'application/json');
  AReq.AddHeader('Authorization', self.Token);
  AReq.AddHeader('If-Match', Bucket.ETag);
  AReq.AddHeader('Prefer', 'return=representation');
  APayload := TStringStream.Create(AJObj.ToJSON);
  AJObj.Free;
  AReq.SourceStream := APayload;
  ARes := self.FExecuteRequest(AReq);
  APayload.Free;

  if ARes.StatusCode = 200 then
  begin
    AJ := TJSONValue.ParseJSONValue(ARes.ContentAsString(TEncoding.UTF8));
    if AJ <> nil then
    begin
      AJ.TryGetValue<string>('id', Bucket.Id);
      AJ.TryGetValue<string>('name', Bucket.Name);
      AJ.TryGetValue<string>('planId', Bucket.PlanId);
      AJ.TryGetValue<string>('orderHint', Bucket.OrderHint);
      self.GetValue(AJ, '@odata.etag', Bucket.ETag);
      AJ.Free;
    end;
  end
  else
  begin
    self.handleError(AReq, ARes);
  end;
end;

procedure TMsPlanner.DeleteBucket(var Bucket: TMsPlannerBucket);
var
  // requests
  AReq: IHttpRequest;
  ARes: IHTTPResponse;
begin
  if Bucket.ETag = '' then
  begin
    self.GetBucket(Bucket);
  end;

  AReq := self.Http.GetRequest(sHTTPMethodDelete, self.buildUrl('planner/buckets/' + Bucket.Id));
  AReq.AddHeader('Content-Type', 'application/json');
  AReq.AddHeader('Accept', 'application/json');
  AReq.AddHeader('Authorization', self.Token);
  AReq.AddHeader('If-Match', Bucket.ETag);
  ARes := self.FExecuteRequest(AReq);

  if ARes.StatusCode = 204 then
  begin
    Bucket.Id := '';
  end
  else
  begin
    self.handleError(AReq, ARes);
  end;
end;

procedure TMsPlanner.MapCategories(Planner: TMsPlannerPlanner; var Task: TMsPlannerTask);
var
  I: Integer;
  AI: Integer;
begin
  for I := 0 to length(Task.AppliedCategories) - 1 do
  begin
    for AI := 0 to length(Planner.Categories) - 1 do
    begin
      if Planner.Categories[AI].Id = Task.AppliedCategories[I].Id then
      begin
        Task.AppliedCategories[I].Name := Planner.Categories[AI].Name;
        break;
      end;
    end;
  end;
end;

end.