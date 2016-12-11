(*
  Copyright 2015-2016, WiRL - REST Library

  Home: https://github.com/WiRL-library

*)
unit WiRL.Core.Application;

{$I WiRL.inc}

interface

uses
  System.SysUtils, System.Classes, System.Rtti,
  System.Generics.Collections,
  WiRL.Core.Classes,
  WiRL.Core.MessageBodyWriter,
  WiRL.Core.Registry,
  WiRL.Core.MediaType,
  WiRL.Core.Token,
  WiRL.Core.Context,
  WiRL.http.Filters;

type
  {$SCOPEDENUMS ON}
  TAuthTokenLocation = (Bearer, Cookie, Header);
  TSecretGenerator = reference to function(): TBytes;
  TAttributeArray = TArray<TCustomAttribute>;
  TArgumentArray = array of TValue;


  TWiRLApplication = class
  private
    //256bit encoding key
    const SCRT_SGN = 'd2lybC5zdXBlcnNlY3JldC5zZWVkLmZvci5zaWduaW5n';
  private
    class var FRttiContext: TRttiContext;
  private
    FSecret: TBytes;
    FResourceRegistry: TObjectDictionary<string, TWiRLConstructorInfo>;
    FFilterRegistry: TWiRLFilterRegistry;
    FBasePath: string;
    FName: string;
    FClaimClass: TWiRLSubjectClass;
    FSystemApp: Boolean;
    FTokenCustomHeader: string;
    FTokenLocation: TAuthTokenLocation;
    function GetResources: TArray<string>;
    function GetResourceCtor(const AResourceName: string): TWiRLConstructorInfo;
    function AddResource(AResource: string): Boolean;
    function AddFilter(AFilter: string): Boolean;
    function GetSecret: TBytes;
  public
    class procedure InitializeRtti;

    constructor Create;
    destructor Destroy; override;

    // Fluent-like configuration methods
    function SetResources(const AResources: TArray<string>): TWiRLApplication;
    function SetFilters(const AFilters: TArray<string>): TWiRLApplication;
    function SetSecret(const ASecret: TBytes): TWiRLApplication; overload;
    function SetSecret(ASecretGen: TSecretGenerator): TWiRLApplication; overload;
    function SetBasePath(const ABasePath: string): TWiRLApplication;
    function SetTokenLocation(ALocation: TAuthTokenLocation): TWiRLApplication;
    function SetTokenCustomHeader(const ACustomHeader: string): TWiRLApplication;
    function SetName(const AName: string): TWiRLApplication;
    function SetClaimsClass(AClaimClass: TWiRLSubjectClass): TWiRLApplication;
    function SetSystemApp(ASystem: Boolean): TWiRLApplication;

    property Name: string read FName;
    property BasePath: string read FBasePath;
    property SystemApp: Boolean read FSystemApp;
    property ClaimClass: TWiRLSubjectClass read FClaimClass;
    property FilterRegistry: TWiRLFilterRegistry read FFilterRegistry write FFilterRegistry;
    property Resources: TArray<string> read GetResources;
    property Secret: TBytes read GetSecret;
    property TokenLocation: TAuthTokenLocation read FTokenLocation;
    property TokenCustomHeader: string read FTokenCustomHeader;

    class property RttiContext: TRttiContext read FRttiContext;
  end;

  TWiRLApplicationDictionary = class(TObjectDictionary<string, TWiRLApplication>)
  end;

  TWiRLApplicationWorker = class
  private
    FContext: TWiRLContext;
    FAppConfig: TWiRLApplication;
    FAuthContext: TWiRLAuthContext;
    FResourceType: TRttiType;
    FResourceCtor: TWiRLConstructorInfo;
    FResourceMethod: TRttiMethod;

    procedure CollectGarbage(const AValue: TValue);
    function GetResourceMethod: TRttiMethod;
    function GetMethodConsumes(AMethod: TRttiMethod): TMediaTypeList;
    function GetMethodProduces(AMethod: TRttiMethod): TMediaTypeList;
    function GetResourceType: TRttiType;
  protected
    procedure InternalHandleRequest;

    function CheckFilterBinding(AFilterClass, AResourceClass: TClass): Boolean;

    procedure ContextInjection(AInstance: TObject);
    function ContextInjectionByType(const AType: TClass; out AValue: TValue): Boolean;

    procedure CheckAuthorization(AAuth: TWiRLAuthContext);
    function FillAnnotatedParam(AParam: TRttiParameter; const AAttrArray: TAttributeArray; AResourceInstance: TObject): TValue;
    function FillNonAnnotatedParam(AParam: TRttiParameter): TValue;
    procedure FillResourceMethodParameters(AInstance: TObject; var AArgumentArray: TArgumentArray);
    procedure InvokeResourceMethod(AInstance: TObject; const AWriter: IMessageBodyWriter; AMediaType: TMediaType); virtual;
    function ParamNameToParamIndex(AResourceInstance: TObject; const AParamName: string): Integer;

    procedure AuthContextFromConfig(AContext: TWiRLAuthContext);
    function GetAuthContext: TWiRLAuthContext;
  public
    constructor Create(AContext: TWiRLContext; AAppConfig: TWiRLApplication);
    destructor Destroy; override;

    // Filters handling
    procedure ApplyRequestFilters;
    procedure ApplyResponseFilters;
    // HTTP Request handling
    procedure HandleRequest;
  end;


implementation

uses
  System.StrUtils, System.TypInfo,
  WiRL.Core.Request,
  WiRL.Core.Response,
  WiRL.Core.Exceptions,
  WiRL.Core.Utils,
  WiRL.Rtti.Utils,
  WiRL.Core.URL,
  WiRL.Core.Attributes,
  WiRL.Core.Engine,
  WiRL.Core.JSON;

function ExtractToken(const AString: string; const ATokenIndex: Integer; const ADelimiter: Char = '/'): string;
var
  LTokens: TArray<string>;
begin
  LTokens := TArray<string>(SplitString(AString, ADelimiter));

  Result := '';
  if ATokenIndex < Length(LTokens) then
    Result := LTokens[ATokenIndex]
  else
    raise EWiRLServerException.Create(
      Format('ExtractToken, index: %d from %s', [ATokenIndex, AString]), 'ExtractToken');
end;

{ TWiRLApplication }

function TWiRLApplication.AddFilter(AFilter: string): Boolean;
var
  LRegistry: TWiRLFilterRegistry;
  LInfo: TWiRLFilterConstructorInfo;
begin
  Result := False;
  LRegistry := TWiRLFilterRegistry.Instance;

  if IsMask(AFilter) then // has wildcards and so on...
  begin
    for LInfo in LRegistry do
    begin
      if MatchesMask(LInfo.TypeTClass.QualifiedClassName, AFilter) then
      begin
        FFilterRegistry.Add(LInfo);
        Result := True;
      end;
    end;
  end
  else // exact match
  begin
    if LRegistry.FilterByClassName(AFilter, LInfo) then
    begin
      FFilterRegistry.Add(LInfo);
      Result := True;
    end;
  end;
end;

function TWiRLApplication.AddResource(AResource: string): Boolean;

  function AddResourceToApplicationRegistry(const AInfo: TWiRLConstructorInfo): Boolean;
  var
    LClass: TClass;
    LResult: Boolean;
  begin
    LResult := False;
    LClass := AInfo.TypeTClass;
    TRttiHelper.HasAttribute<PathAttribute>(FRttiContext.GetType(LClass),
      procedure (AAttribute: PathAttribute)
      var
        LURL: TWiRLURL;
      begin
        LURL := TWiRLURL.CreateDummy(AAttribute.Value);
        try
          if not FResourceRegistry.ContainsKey(LURL.PathTokens[0]) then
          begin
            FResourceRegistry.Add(LURL.PathTokens[0], AInfo.Clone);
            LResult := True;
          end;
        finally
          LURL.Free;
        end;
      end
    );
    Result := LResult;
  end;

var
  LRegistry: TWiRLResourceRegistry;
  LInfo: TWiRLConstructorInfo;
  LKey: string;
begin
  Result := False;
  LRegistry := TWiRLResourceRegistry.Instance;

  if IsMask(AResource) then // has wildcards and so on...
  begin
    for LKey in LRegistry.Keys.ToArray do
    begin
      if MatchesMask(LKey, AResource) then
      begin
        if LRegistry.TryGetValue(LKey, LInfo) and AddResourceToApplicationRegistry(LInfo) then
          Result := True;
      end;
    end;
  end
  else // exact match
    if LRegistry.TryGetValue(AResource, LInfo) then
      Result := AddResourceToApplicationRegistry(LInfo);
end;

function TWiRLApplication.SetBasePath(const ABasePath: string): TWiRLApplication;
begin
  FBasePath := ABasePath;
  Result := Self;
end;

function TWiRLApplication.SetName(const AName: string): TWiRLApplication;
begin
  FName := AName;
  Result := Self;
end;

function TWiRLApplication.SetClaimsClass(AClaimClass: TWiRLSubjectClass): TWiRLApplication;
begin
  FClaimClass := AClaimClass;
  Result := Self;
end;

function TWiRLApplication.SetFilters(const AFilters: TArray<string>): TWiRLApplication;
var
  LFilter: string;
begin
  Result := Self;
  for LFilter in AFilters do
    Self.AddFilter(LFilter);
end;

function TWiRLApplication.SetResources(const AResources: TArray<string>): TWiRLApplication;
var
  LResource: string;
begin
  Result := Self;
  for LResource in AResources do
    Self.AddResource(LResource);
end;

function HasNameBindingAttribute(AClass :TRttiType; AMethod: TRttiMethod; Attrib :TCustomAttribute) :Boolean;
var
  LHasAttrib :Boolean;
begin
  // First search inside the method attributes
  LHasAttrib := False;
  TRttiHelper.ForEachAttribute<TCustomAttribute>(AMethod,
    procedure (AMethodAttrib: TCustomAttribute)
    begin
      if AMethodAttrib is Attrib.ClassType then
        LHasAttrib := True;
    end
  );

  // Then inside the class attributes
  if not LHasAttrib then
  begin
    TRttiHelper.ForEachAttribute<TCustomAttribute>(AClass,
      procedure (AMethodAttrib: TCustomAttribute)
      begin
        if AMethodAttrib is Attrib.ClassType then
          LHasAttrib := True;
      end
    );
  end;

  Result := LHasAttrib;
end;

constructor TWiRLApplication.Create;
begin
  inherited Create;
  FResourceRegistry := TObjectDictionary<string, TWiRLConstructorInfo>.Create([doOwnsValues]);
  FFilterRegistry := TWiRLFilterRegistry.Create;
  FFilterRegistry.OwnsObjects := False;
  FSecret := TEncoding.ANSI.GetBytes(SCRT_SGN);
end;

destructor TWiRLApplication.Destroy;
begin
  FResourceRegistry.Free;
  FFilterRegistry.Free;
  inherited;
end;

function TWiRLApplication.GetResourceCtor(const AResourceName: string): TWiRLConstructorInfo;
begin
  FResourceRegistry.TryGetValue(AResourceName, Result);
end;

function TWiRLApplication.GetResources: TArray<string>;
begin
  Result := FResourceRegistry.Keys.ToArray;
end;

function TWiRLApplication.GetSecret: TBytes;
begin
  Result := FSecret;
end;

class procedure TWiRLApplication.InitializeRtti;
begin
  FRttiContext := TRttiContext.Create;
end;

function TWiRLApplication.SetSecret(ASecretGen: TSecretGenerator): TWiRLApplication;
begin
  if Assigned(ASecretGen) then
    FSecret := ASecretGen;
  Result := Self;
end;

function TWiRLApplication.SetSecret(const ASecret: TBytes): TWiRLApplication;
begin
  FSecret := ASecret;
  Result := Self;
end;

function TWiRLApplication.SetSystemApp(ASystem: Boolean): TWiRLApplication;
begin
  FSystemApp := ASystem;
  Result := Self;
end;

function TWiRLApplication.SetTokenCustomHeader(const ACustomHeader: string): TWiRLApplication;
begin
  FTokenCustomHeader := ACustomHeader;
  Result := Self;
end;

function TWiRLApplication.SetTokenLocation(ALocation: TAuthTokenLocation): TWiRLApplication;
begin
  FTokenLocation := ALocation;
  Result := Self;
end;

{ TWiRLApplicationWorker }

constructor TWiRLApplicationWorker.Create(AContext: TWiRLContext; AAppConfig: TWiRLApplication);
begin
  FContext := AContext;
  FAppConfig := AAppConfig;

  // Saves the resource constructor (if found)
  FResourceCtor := FAppConfig.GetResourceCtor(FContext.URL.Resource);

  // Saves the resource type (if found)
  FResourceType := GetResourceType;

  // Saves the resource method (if found)
  FResourceMethod := GetResourceMethod;
end;

destructor TWiRLApplicationWorker.Destroy;
begin

  inherited;
end;

procedure TWiRLApplicationWorker.ApplyRequestFilters;
var
  LFilterImpl: TObject;
  LRequestFilter: IWiRLContainerRequestFilter;
begin
  // Find resource type
  if not Assigned(FResourceType) then
    Exit;

  // Find resource method
  if not Assigned(FResourceMethod) then
    Exit;

  // Run filters
  FAppConfig.FilterRegistry.FetchRequestFilter(False,
    procedure (ConstructorInfo: TWiRLFilterConstructorInfo)
    begin
      if CheckFilterBinding(ConstructorInfo.TypeTClass, FResourceCtor.TypeTClass) then
      begin
        LFilterImpl := ConstructorInfo.ConstructorFunc();

        // The check doesn't have any sense but I must use SUPPORT and I hate using it without a check
        if not Supports(LFilterImpl, IWiRLContainerRequestFilter, LRequestFilter) then
          raise EWiRLNotImplementedException.Create(
            Format('Request Filter [%s] does not implement requested interface [IWiRLContainerRequestFilter]', [ConstructorInfo.TypeTClass.ClassName]),
            Self.ClassName,
            'ApplyRequestFilters'
          );
        ContextInjection(LFilterImpl);
        LRequestFilter.Filter(FContext.Request);
      end;
    end
  );
end;

procedure TWiRLApplicationWorker.ApplyResponseFilters;
var
  LFilterImpl: TObject;
  LResponseFilter: IWiRLContainerResponseFilter;
begin
  // Find resource type
  if not Assigned(FResourceType) then
    Exit;

  // Find resource method
  if not Assigned(FResourceMethod) then
    Exit;

  // Run filters
  FAppConfig.FilterRegistry.FetchResponseFilter(
    procedure (ConstructorInfo: TWiRLFilterConstructorInfo)
    begin
      if CheckFilterBinding(ConstructorInfo.TypeTClass, FResourceCtor.TypeTClass) then
      begin
        LFilterImpl := ConstructorInfo.ConstructorFunc();
        // The check doesn't have any sense but I must use SUPPORT and I hate using it without a check
        if not Supports(LFilterImpl, IWiRLContainerResponseFilter, LResponseFilter) then
          raise EWiRLNotImplementedException.Create(
            Format('Response Filter [%s] does not implement requested interface [IWiRLContainerResponseFilter]', [ConstructorInfo.TypeTClass.ClassName]),
            Self.ClassName,
            'ApplyResponseFilters'
          );
        ContextInjection(LFilterImpl);
        LResponseFilter.Filter(FContext.Request, FContext.Response);
      end;
    end
  );
end;

procedure TWiRLApplicationWorker.AuthContextFromConfig(AContext: TWiRLAuthContext);
var
  LToken: string;

  function ExtractJWTToken(const AAuth: string): string;
  var
    LAuthParts: TArray<string>;
  begin
    LAuthParts := AAuth.Split([#32]);
    if Length(LAuthParts) < 2 then
      Exit;

    if SameText(LAuthParts[0], 'Bearer') then
      Result := LAuthParts[1];
  end;

begin
  case FAppConfig.FTokenLocation of
    TAuthTokenLocation.Bearer: LToken := ExtractJWTToken(FContext.Request.Authorization);
    TAuthTokenLocation.Cookie: LToken := FContext.Request.CookieFields.Values['token'];
    TAuthTokenLocation.Header: LToken := FContext.Request.GetFieldByName(FAppConfig.TokenCustomHeader);
  end;

  if LToken.IsEmpty then
    Exit;

  AContext.Verify(LToken, FAppConfig.FSecret);
end;

procedure TWiRLApplicationWorker.CheckAuthorization(AAuth: TWiRLAuthContext);
var
  LDenyAll, LPermitAll, LRolesAllowed: Boolean;
  LAllowedRoles: TStringList;
  LAllowed: Boolean;
  LRole: string;
begin
  LAllowed := True; // Default = True for non annotated-methods
  LDenyAll := False;
  LPermitAll := False;
  LAllowedRoles := TStringList.Create;
  try
    LAllowedRoles.Sorted := True;
    LAllowedRoles.Duplicates := TDuplicates.dupIgnore;

    TRttiHelper.ForEachAttribute<AuthorizationAttribute>(FResourceMethod,
      procedure (AAttribute: AuthorizationAttribute)
      begin
        if AAttribute is DenyAllAttribute then
          LDenyAll := True
        else if AAttribute is PermitAllAttribute then
          LPermitAll := True
        else if AAttribute is RolesAllowedAttribute then
        begin
          LRolesAllowed := True;
          LAllowedRoles.AddStrings(RolesAllowedAttribute(AAttribute).Roles);
        end;
      end
    );

  if LDenyAll then
    LAllowed := False
  else
  begin
    if LRolesAllowed then
    begin
      LAllowed := False;
      for LRole in LAllowedRoles do
      begin
        LAllowed := AAuth.Subject.HasRole(LRole);
        if LAllowed then
          Break;
      end;
    end;

    if LPermitAll then
      LAllowed := True;
  end;

  if not LAllowed then
    raise EWiRLNotAuthorizedException.Create('Method call not authorized', Self.ClassName);

  finally
    LAllowedRoles.Free;
  end;
end;

function TWiRLApplicationWorker.CheckFilterBinding(AFilterClass,
    AResourceClass: TClass): Boolean;
var
  LFilterType: TRttiType;
  LResourceType: TRttiType;
  LHasBinding: Boolean;
begin
  LHasBinding := True;
  LFilterType :=  TWiRLApplication.FRttiContext.GetType(AFilterClass);
  LResourceType := TWiRLApplication.FRttiContext.GetType(AResourceClass);

  // Check for attributes that subclass "NameBindingAttribute"
  TRttiHelper.ForEachAttribute<NameBindingAttribute>(LFilterType,
    procedure (AFilterAttrib: NameBindingAttribute)
    begin
      LHasBinding := LHasBinding and HasNameBindingAttribute(LResourceType, FResourceMethod, AFilterAttrib);
    end
  );

  // Check for attributes annotaded by "NameBinding" attribute
  TRttiHelper.ForEachAttribute<TCustomAttribute>(LFilterType,
    procedure (AFilterAttrib: TCustomAttribute)
    begin
      if TRttiHelper.HasAttribute<NameBindingAttribute>(TWiRLApplication.FRttiContext.GetType(AFilterAttrib.ClassType)) then
        LHasBinding := LHasBinding and HasNameBindingAttribute(LResourceType, FResourceMethod, AFilterAttrib);
    end
  );

  Result := LHasBinding;
end;

procedure TWiRLApplicationWorker.CollectGarbage(const AValue: TValue);
var
  LIndex: Integer;
  LValue: TValue;
begin
  case AValue.Kind of
    tkClass: AValue.AsObject.Free;

    tkInterface: TObject(AValue.AsInterface).Free;

    tkArray,
    tkDynArray:
    begin
      for LIndex := 0 to AValue.GetArrayLength -1 do
      begin
        LValue := AValue.GetArrayElement(LIndex);
        case LValue.Kind of
          tkClass: LValue.AsObject.Free;
          tkInterface: TObject(LValue.AsInterface).Free;
          tkArray, tkDynArray: CollectGarbage(LValue); //recursion
        end;
      end;
    end;
  end;
end;

procedure TWiRLApplicationWorker.ContextInjection(AInstance: TObject);
var
  LType: TRttiType;
begin
  LType := TWiRLApplication.FRttiContext.GetType(AInstance.ClassType);
  // Context injection
  TRttiHelper.ForEachFieldWithAttribute<ContextAttribute>(LType,
    function (AField: TRttiField; AAttrib: ContextAttribute): Boolean
    var
      LFieldClassType: TClass;
      LValue: TValue;
    begin
      Result := True; // enumerate all
      if (AField.FieldType.IsInstance) then
      begin
        LFieldClassType := TRttiInstanceType(AField.FieldType).MetaclassType;

        if not ContextInjectionByType(LFieldClassType, LValue) then
          raise EWiRLServerException.Create(
            Format('Unable to inject class [%s] in resource [%s]', [LFieldClassType.ClassName, AInstance.ClassName]),
            Self.ClassName, 'ContextInjection'
          );

        AField.SetValue(AInstance, LValue);
      end;
    end
  );

  // properties
  TRttiHelper.ForEachPropertyWithAttribute<ContextAttribute>(LType,
    function (AProperty: TRttiProperty; AAttrib: ContextAttribute): Boolean
    var
      LPropertyClassType: TClass;
      LValue: TValue;
    begin
      Result := True; // enumerate all
      if (AProperty.PropertyType.IsInstance) then
      begin
        LPropertyClassType := TRttiInstanceType(AProperty.PropertyType).MetaclassType;
        if ContextInjectionByType(LPropertyClassType, LValue) then
          AProperty.SetValue(AInstance, LValue);
      end;
    end
  );
end;

function TWiRLApplicationWorker.ContextInjectionByType(const AType: TClass; out
    AValue: TValue): Boolean;
begin
  Result := True;
  // AuthContext
  if (AType.InheritsFrom(TWiRLAuthContext)) then
    AValue := FAuthContext
  // Claims (Subject)
  else if (AType.InheritsFrom(TWiRLSubject)) then
    AValue := FAuthContext.Subject
  // HTTP request
  else if (AType.InheritsFrom(TWiRLRequest)) then
    AValue := FContext.Request
  // HTTP response
  else if (AType.InheritsFrom(TWiRLResponse)) then
    AValue := FContext.Response
  // URL info
  else if (AType.InheritsFrom(TWiRLURL)) then
    AValue := FContext.URL
  // Engine
  else if (AType.InheritsFrom(TWiRLEngine)) then
    AValue := FContext.Engine as TWirlEngine
  // Application
  else if (AType.InheritsFrom(TWiRLApplication)) then
    AValue := FAppConfig
  else
    Result := False;
end;

function TWiRLApplicationWorker.FillAnnotatedParam(AParam: TRttiParameter;
    const AAttrArray: TAttributeArray; AResourceInstance: TObject): TValue;
var
  LAttr: TCustomAttribute;
  LParamName, LParamValue: string;
  LParamIndex: Integer;
  LParamClassType: TClass;
  LContextValue: TValue;
begin
  if Length(AAttrArray) > 1 then
    raise EWiRLServerException.Create('Only 1 attribute per param permitted', Self.ClassName);

  LParamName := '';
  LParamValue := '';
  LAttr := AAttrArray[0];

  // context injection
  if (LAttr is ContextAttribute) and (AParam.ParamType.IsInstance) then
  begin
    LParamClassType := TRttiInstanceType(AParam.ParamType).MetaclassType;
    if ContextInjectionByType(LParamClassType, LContextValue) then
      Result := LContextValue;
  end
  else // http values injection
  begin
    if LAttr is PathParamAttribute then
    begin
      LParamName := (LAttr as PathParamAttribute).Value;
      if LParamName = '' then
        LParamName := AParam.Name;

      LParamIndex := ParamNameToParamIndex(AResourceInstance, LParamName);
      LParamValue := FContext.URL.PathTokens[LParamIndex];
    end
    else
    if LAttr is QueryParamAttribute then
    begin
      LParamName := (LAttr as QueryParamAttribute).Value;
      if LParamName = '' then
        LParamName := AParam.Name;

      // Prendere il valore (come stringa) dalla lista QueryFields
      LParamValue := FContext.Request.QueryFields.Values[LParamName];
    end
    else
    if LAttr is FormParamAttribute then
    begin
      LParamName := (LAttr as FormParamAttribute).Value;
      if LParamName = '' then
        LParamName := AParam.Name;

      // Prendere il valore (come stringa) dalla lista ContentFields
      LParamValue := FContext.Request.ContentFields.Values[LParamName];
    end
    else
    if LAttr is CookieParamAttribute then
    begin
      LParamName := (LAttr as CookieParamAttribute).Value;
      if LParamName = '' then
        LParamName := AParam.Name;

      // Prendere il valore (come stringa) dalla lista CookieFields
      LParamValue := FContext.Request.CookieFields.Values[LParamName];
    end
    else
    if LAttr is HeaderParamAttribute then
    begin
      LParamName := (LAttr as HeaderParamAttribute).Value;
      if LParamName = '' then
        LParamName := AParam.Name;

      // Prendere il valore (come stringa) dagli Header HTTP
      LParamValue := FContext.Request.GetFieldByName(LParamName);
    end
    else
    if LAttr is BodyParamAttribute then
    begin
      LParamName := AParam.Name;
      LParamValue := FContext.Request.Content;
    end;

    case AParam.ParamType.TypeKind of
      tkInt64,
      tkInteger: Result := TValue.From(StrToInt(LParamValue));
      tkFloat: Result := TValue.From<Double>(StrToFloat(LParamValue));

      tkChar: Result := TValue.From(AnsiChar(LParamValue[1]));
      tkWChar: ;
      tkEnumeration: ;
      tkSet: ;
      tkClass:
      begin
        // TODO: better error handling in case of an invalid type cast
        // TODO: add a dynamic way to create the right class
        if MatchStr(AParam.ParamType.Name, ['TJSONObject']) then
          Result := TJSONObject.ParseJSONValue(LParamValue) as TJSONObject
        else if MatchStr(AParam.ParamType.Name, ['TJSONArray']) then
          Result := TJSONObject.ParseJSONValue(LParamValue) as TJSONArray
        else if MatchStr(AParam.ParamType.Name, ['TJSONValue']) then
          Result := TJSONObject.ParseJSONValue(LParamValue) as TJSONValue
        else
          raise EWiRLServerException.Create(Format('Unsupported class [%s] for param [%s]', [AParam.ParamType.Name, LParamName]), Self.ClassName);
      end;

      tkMethod: ;

      tkLString,
      tkUString,
      tkWString,
      tkString: Result := TValue.From(LParamValue);

      tkVariant: Result := TValue.From(LParamValue);

      tkArray: ;
      tkRecord: ;
      tkInterface: ;
      tkDynArray: ;
      tkClassRef: ;
      tkPointer: ;
      tkProcedure: ;
    else
      raise EWiRLServerException.Create(Format('Unsupported data type for param [%s]', [LParamName]), Self.ClassName);
    end;
  end;
end;

function TWiRLApplicationWorker.FillNonAnnotatedParam(AParam: TRttiParameter):
    TValue;
var
  LClass: TClass;
begin
  // 1) Valid objects (TWiRLRequest, )
  if AParam.ParamType.IsInstance then
  begin
    LClass := AParam.ParamType.AsInstance.MetaclassType;
    if LClass.InheritsFrom(TWiRLRequest) then
      Result := TValue.From(FContext.Request)
    else
      Result := TValue.From(nil);
      //Exception.Create('Only TWiRLRequest object if the method is not annotated');
  end
  else
  begin
    // 2) parameter default value
    Result := TValue.Empty;
  end;
end;

procedure TWiRLApplicationWorker.FillResourceMethodParameters(AInstance:
    TObject; var AArgumentArray: TArgumentArray);
var
  LParam: TRttiParameter;
  LParamArray: TArray<TRttiParameter>;
  LAttrArray: TArray<TCustomAttribute>;

  LIndex: Integer;
begin
  try
    LParamArray := FResourceMethod.GetParameters;

    // The method has no parameters so simply call as it is
    if Length(LParamArray) = 0 then
      Exit;

    SetLength(AArgumentArray, Length(LParamArray));

    for LIndex := Low(LParamArray) to High(LParamArray) do
    begin
      LParam := LParamArray[LIndex];

      LAttrArray := LParam.GetAttributes;

      if Length(LAttrArray) = 0 then
        AArgumentArray[LIndex] := FillNonAnnotatedParam(LParam)
      else
        AArgumentArray[LIndex] := FillAnnotatedParam(LParam, LAttrArray, AInstance);
    end;

  except
    on E: Exception do
    begin
      raise EWiRLWebApplicationException.Create(E, 400,
        TValuesUtil.MakeValueArray(
          Pair.S('issuer', Self.ClassName),
          Pair.S('method', 'FillResourceMethodParameters')
         )
        );
     end;
  end;
end;

function TWiRLApplicationWorker.GetAuthContext: TWiRLAuthContext;
begin
  if Assigned(FAppConfig.FClaimClass) then
    Result := TWiRLAuthContext.Create(FAppConfig.FClaimClass)
  else
    Result := TWiRLAuthContext.Create;

  AuthContextFromConfig(Result);
end;

function TWiRLApplicationWorker.GetResourceMethod: TRttiMethod;
var
  LMethod: TRttiMethod;
  LResourcePath: string;
  LAttribute: TCustomAttribute;
  LPrototypeURL: TWiRLURL;
  LPathMatches,
  LProducesMatch,
  LHttpMethodMatches: Boolean;
  LMethodPath: string;
  LMethodProduces: TMediaTypeList;

begin
  Result := nil;
  LResourcePath := '';

  if not Assigned(FResourceType) then
    Exit;

  TRttiHelper.HasAttribute<PathAttribute>(FResourceType,
    procedure (APathAttribute: PathAttribute)
    begin
      LResourcePath := APathAttribute.Value;
    end
  );

  for LMethod in FResourceType.GetMethods do
  begin
    LMethodPath := '';
    LHttpMethodMatches := False;
    LPathMatches := False;
    LProducesMatch := False;

    // Match the HTTP method
    for LAttribute in LMethod.GetAttributes do
    begin
      if LAttribute is PathAttribute then
        LMethodPath := PathAttribute(LAttribute).Value;

      if LAttribute is HttpMethodAttribute then
        LHttpMethodMatches := HttpMethodAttribute(LAttribute).Matches(FContext.Request);
    end;

    if LHttpMethodMatches then
    begin
      LPrototypeURL := TWiRLURL.CreateDummy([TWiRLEngine(FContext.Engine).BasePath, FAppConfig.BasePath, LResourcePath, LMethodPath]);
      try
        LPathMatches := LPrototypeURL.MatchPath(FContext.URL);
      finally
        LPrototypeURL.Free;
      end;
    end;

    // Match the Produces MediaType
    LMethodProduces := GetMethodProduces(LMethod);
    try
      if Length(FContext.Request.AcceptableMediaTypes.Intersect(LMethodProduces)) > 0 then
        LProducesMatch := True;
    finally
      LMethodProduces.Free;
    end;

    if LPathMatches and LHttpMethodMatches and LProducesMatch then
    begin
      Result := LMethod;
      Break;
    end;

  end;
end;

function TWiRLApplicationWorker.GetMethodConsumes(AMethod: TRttiMethod): TMediaTypeList;
var
  LList: TMediaTypeList;
begin
  LList := TMediaTypeList.Create;

  TRttiHelper.ForEachAttribute<ConsumesAttribute>(AMethod,
    procedure (AConsumes: ConsumesAttribute)
    var
      LMediaList: TArray<string>;
      LMedia: string;
    begin
      LMediaList := AConsumes.Value.Split([',']);

      for LMedia in LMediaList do
        LList.Add(TMediaType.Create(LMedia));
    end
  );

  Result := LList;
end;

function TWiRLApplicationWorker.GetMethodProduces(AMethod: TRttiMethod): TMediaTypeList;
var
  LList: TMediaTypeList;
begin
  LList := TMediaTypeList.Create;

  TRttiHelper.ForEachAttribute<ProducesAttribute>(AMethod,
    procedure (AProduces: ProducesAttribute)
    var
      LMediaList: TArray<string>;
      LMedia: string;
    begin
      LMediaList := AProduces.Value.Split([',']);

      for LMedia in LMediaList do
        LList.Add(TMediaType.Create(LMedia));
    end
  );

  Result := LList;
end;

function TWiRLApplicationWorker.GetResourceType: TRttiType;
begin
  if Assigned(FResourceCtor) then
    Result := TWiRLApplication.RttiContext.GetType(FResourceCtor.TypeTClass)
  else
    Result := nil;
end;

procedure TWiRLApplicationWorker.HandleRequest;
begin
  FAuthContext := GetAuthContext;
  try
    InternalHandleRequest;
  finally
    FAuthContext.Free;
  end;
end;

procedure TWiRLApplicationWorker.InternalHandleRequest;
var
  LInstance: TObject;
  LWriter: IMessageBodyWriter;
  LMediaType: TMediaType;
begin
  if not Assigned(FResourceType) then
    raise EWiRLNotFoundException.Create(
      Format('Resource [%s] not found', [FContext.URL.Resource]),
      Self.ClassName, 'HandleRequest'
    );

  if not Assigned(FResourceMethod) then
    raise EWiRLNotFoundException.Create(
      Format('Resource''s method [%s] not found to handle resource [%s]', [FContext.Request.Method, FContext.URL.Resource + FContext.URL.SubResources.ToString]),
      Self.ClassName, 'HandleRequest'
    );

  CheckAuthorization(FAuthContext);

  LInstance := FResourceCtor.ConstructorFunc();
  try
    TWiRLMessageBodyRegistry.Instance.FindWriter(
      FResourceMethod,
      FContext.Request.AcceptableMediaTypes,
      LWriter,
      LMediaType
    );

    ContextInjection(LInstance);
    try
      InvokeResourceMethod(LInstance, LWriter, LMediaType);
    finally
      LWriter := nil;
      LMediaType.Free;
    end;

  finally
    LInstance.Free;
  end;
end;

procedure TWiRLApplicationWorker.InvokeResourceMethod(AInstance: TObject;
  const AWriter: IMessageBodyWriter; AMediaType: TMediaType);
var
  LMethodResult: TValue;
  LArgument: TValue;
  LArgumentArray: TArgumentArray;
  LStream: TMemoryStream;
  LContentType: string;
begin
  // The returned object MUST be initially nil (needs to be consistent with the Free method)
  LMethodResult := nil;
  try
    LContentType := FContext.Response.ContentType;
    FillResourceMethodParameters(AInstance, LArgumentArray);
    LMethodResult := FResourceMethod.Invoke(AInstance, LArgumentArray);

    if LMethodResult.IsInstanceOf(TWiRLResponse) then
    begin
      // Request is already done
    end
    else if Assigned(AWriter) then // MessageBodyWriters mechanism
    begin
      if FContext.Response.ContentType = LContentType then
        FContext.Response.ContentType := AMediaType.ToString;

      LStream := TMemoryStream.Create;
      try
        AWriter.WriteTo(LMethodResult, FResourceMethod.GetAttributes, AMediaType, FContext.Response.CustomHeaders, LStream);
        LStream.Position := 0;
        FContext.Response.ContentStream := LStream;
      except
        on E: Exception do
        begin
          LStream.Free;
          raise EWiRLServerException.Create(E.Message, 'TWiRLApplicationWorker', 'InvokeResourceMethod');
        end;
      end;
    end
    else // fallback (no MBW, no TWiRLResponse)
    begin
      // handle result
      case LMethodResult.Kind of

        tkString, tkLString, tkUString, tkWString, // string types
        tkInteger, tkInt64, tkFloat, tkVariant:    // Treated as string, nothing more
        begin
          FContext.Response.Content := LMethodResult.AsString;
          if (FContext.Response.ContentType = LContentType) then
            FContext.Response.ContentType := TMediaType.TEXT_PLAIN; // or check Produces of method!
          FContext.Response.StatusCode := 200;
        end;

        tkUnknown : ; // it's a procedure, not a function!

        //tkRecord: ;
        //tkInterface: ;
        //tkDynArray: ;
        else
          raise EWiRLNotImplementedException.Create(
            'Resource''s returned type not supported',
            Self.ClassName, 'InvokeResourceMethod'
          );
      end;
    end;
  finally
    if (not TRttiHelper.HasAttribute<SingletonAttribute>(FResourceMethod)) then
      CollectGarbage(LMethodResult);
    for LArgument in LArgumentArray do
      CollectGarbage(LArgument);
  end;
end;

function TWiRLApplicationWorker.ParamNameToParamIndex(AResourceInstance: TObject;
  const AParamName: string): Integer;
var
  LParamIndex: Integer;
  LAttrib: TCustomAttribute;
  LSubResourcePath: string;
begin
  LParamIndex := -1;

  LSubResourcePath := '';
  for LAttrib in FResourceMethod.GetAttributes do
  begin
    if LAttrib is PathAttribute then
    begin
      LSubResourcePath := PathAttribute(LAttrib).Value;
      Break;
    end;
  end;

  TRttiHelper.HasAttribute<PathAttribute>(TWiRLApplication.RttiContext.GetType(AResourceInstance.ClassType),
    procedure (AResourcePathAttrib: PathAttribute)
    var
      LResURL: TWiRLURL;
      LPair: TPair<Integer, string>;
    begin
      LResURL := TWiRLURL.CreateDummy([TWiRLEngine(FContext.Engine).BasePath, FAppConfig.BasePath, AResourcePathAttrib.Value, LSubResourcePath]);
      try
        LParamIndex := -1;
        for LPair in LResURL.PathParams do
        begin
          if SameText(AParamName, LPair.Value) then
          begin
            LParamIndex := LPair.Key;
            Break;
          end;
        end;
      finally
        LResURL.Free;
      end;
    end
  );

  Result := LParamIndex;
end;

initialization
  TWiRLApplication.InitializeRtti;

end.
