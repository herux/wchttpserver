{
 wcHTTP2Con
   Classes and other routings to deal with HTTP2 connections,
   frames and streams
   plus cross-protocols conversions HTTP2 <-> HTTP1.1 for
   fpHTTP/fpweb compability

   Part of WCHTTPServer project

   Copyright (c) 2020-2021 by Ilya Medvedkov

   This program is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
}

unit wcHTTP2Con;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

uses
  {$ifdef wiki_docs}
  fpcweb, commonutils,
  {$endif}
  Classes, SysUtils,
  ECommonObjs, OGLFastList,
  fphttp, HTTPDefs, httpprotocol, AbstractHTTPServer,
  wcNetworking,
  BufferedStream,
  ExtMemoryStream,
  extuhpack,
  HTTP2Consts,
  HTTP1Utils,
  HTTP2HTTP1Conv
  {$ifdef DEBUG_STAT}
  , wcDebug_vars
  {$endif};

type
  TWCHTTP2Streams = class;
  TWCHTTP2Connection = class;
  TWCHTTP2Stream = class;
  TWCHTTP2Settings = class;

  { TWCHTTP2FrameHeader }

  TWCHTTP2FrameHeader = class
  public
    PayloadLength : Integer; //24 bit
    FrameType : Byte;
    FrameFlag : Byte;
    StreamID  : Cardinal;
    Reserved  : Byte;
    procedure LoadFromStream(Str : TStream);
    procedure SaveToStream(Str : TStream);
  end;

  { TWCHTTP2Frame }

  TWCHTTP2Frame = class(TWCRefProtoFrame)
  public
    Header  : TWCHTTP2FrameHeader;
    Stream  : TWCHTTP2Stream;
    constructor Create(aFrameType: Byte; aStr: TWCHTTP2Stream; aFrameFlags: Byte);
    destructor Destroy; override;
    procedure SaveToStream(Str : TStream); override;
    function Memory : Pointer; override;
    function Size : Int64; override;
  end;
  
  { TWCHTTP2DataFrame }
  
  TWCHTTP2DataFrame = class(TWCHTTP2Frame)
  public
    Payload : Pointer;
    OwnPayload : Boolean;
    constructor Create(aFrameType: Byte;
      aStream: TWCHTTP2Stream; aFrameFlags: Byte;
      aData: Pointer; aDataSize: Cardinal; aOwnPayload: Boolean = true); overload;
    function Memory : Pointer; override;
    destructor Destroy; override;
    procedure SaveToStream(Str : TStream); override;
  end;

  { TWCHTTP2RefFrame }

  TWCHTTP2RefFrame = class(TWCHTTP2Frame)
  public
    FStrm : TReferencedStream;
    Fpos : Int64;
    constructor Create(aFrameType : Byte;
                       aStream: TWCHTTP2Stream;
                       aFrameFlags : Byte;
                       aData : TReferencedStream;
                       aStrmPos : Int64;
                       aDataSize : Cardinal);
    function Memory : Pointer; override;
    destructor Destroy; override;
    procedure SaveToStream(Str : TStream); override;
  end;

  { TWCHTTP2AdvFrame }

  TWCHTTP2AdvFrame = class(TWCRefProtoFrame)
  public
    procedure SaveToStream(Str : TStream); override;
    function Memory : Pointer; override;
    function Size : Int64; override;
  end;

  { TWCHTTP2UpgradeResponseFrame }

  TWCHTTP2UpgradeResponseFrame = class(TWCRefProtoFrame)
  private
    FMode : THTTP2OpenMode;
  public
    constructor Create(Mode : THTTP2OpenMode);
    procedure SaveToStream(Str : TStream); override;
    function Memory : Pointer; override;
    function Size : Int64; override;
  end;

  { TWCHTTP2Block }

  TWCHTTP2Block = class
  private
    FData          : TExtMemoryStream;
    FConnection    : TWCHTTP2Connection;
    FStream        : TWCHTTP2Stream;
    function GetDataBlock : TExtMemoryStream;
    function GetDataBlockSize : Integer;
  public
    constructor Create(aConnection : TWCHTTP2Connection;
                       aStream : TWCHTTP2Stream); virtual;
    destructor Destroy; override;
    // avaible data
    procedure PushData(aData : Pointer; sz : Cardinal); overload;
    procedure PushData(Strm: TStream; startAt: Int64); overload;
    procedure PushData(Strings: TStrings); overload;
    procedure Clean;
    property  Stream : TWCHTTP2Stream read FStream;
    property  Data : TExtMemoryStream read GetDataBlock;
    property  DataBlockSize : Integer read GetDataBlockSize;
  end;

  { TWCHTTP2SerializeStream }

  TWCHTTP2SerializeStream = class(TStream)
  private
    FConn  : TWCHTTP2Connection;
    FStream  : TWCHTTP2Stream;
    FCurFrame : TWCHTTP2DataFrame;
    FFirstFrameType, FNextFramesType : Byte;
    FFlags, FFinalFlags : Byte;
    FRestFrameSz : Longint;
    FChunked : Boolean;
    FFirstFramePushed : Boolean;
  public
    constructor Create(aConn: TWCHTTP2Connection;
                       aStrm: TWCHTTP2Stream;
                       aFirstFrameType : Byte;
                       aNextFramesType : Byte;
                       aFlags, aFinalFlags: Byte);
    function Write(const Buffer; Count: Longint): Longint; override;
    procedure Flush;
    destructor Destroy; override;

    property FirstFrameType : Byte read FFirstFrameType write FFirstFrameType;
    property NextFramesType : Byte read FNextFramesType write FNextFramesType;
    property Flags : Byte read FFlags write FFlags;
    property FinalFlags : Byte read FFinalFlags write FFinalFlags;
    property Chunked : Boolean read FChunked write FChunked;
  end;

  { TThreadSafeHPackEncoder }

  TThreadSafeHPackEncoder = class(TNetAutoReferencedObject)
  private
    FEncoder : THPackEncoder;
  public
    constructor Create(TableSize : Cardinal);
    destructor Destroy; override;
    procedure EncodeHeader(aOutStream: TStream;
                       const aName: RawByteString;
                       const aValue: RawByteString; const aSensitive: Boolean);
  end;

  { TThreadSafeHPackDecoder }

  TThreadSafeHPackDecoder = class(TNetAutoReferencedObject)
  private
    FDecoder : THPackDecoder;
    function GetDecodedHeaders: THPackHeaderTextList;
  public
    constructor Create(HeadersListSize, TableSize: Cardinal);
    destructor Destroy; override;
    procedure Decode(aStream: TStream);
    function Malformed: Boolean;
    property  DecodedHeaders: THPackHeaderTextList read GetDecodedHeaders;
  end;

  { TWCHTTP2ResponseHeaderPusher }

  TWCHTTP2ResponseHeaderPusher = class
  private
    FMem : TExtMemoryStream;
    FHPackEncoder : TThreadSafeHPackEncoder;
  protected
    property HPackEncoder : TThreadSafeHPackEncoder read FHPackEncoder write FHPackEncoder;
  public
    constructor Create(aHPackEncoder : TThreadSafeHPackEncoder);
    destructor Destroy; override;
    procedure PushHeader(const H, V : String); virtual; abstract;
    procedure PushAll(R: TAbsHTTPConnectionResponse);
  end;

  { TWCHTTP2BufResponseHeaderPusher }

  TWCHTTP2BufResponseHeaderPusher = class(TWCHTTP2ResponseHeaderPusher)
  private
    FBuf : Pointer;
    FCapacity : Cardinal;
    FSize : Cardinal;
    FBufGrowValue : Cardinal;
  public
    constructor Create(aHPackEncoder : TThreadSafeHPackEncoder;
                       aBuffer : Pointer;
                       aBufferSize,
                       aBufGrowValue : Cardinal);
    procedure PushHeader(const H, V : String); override;
    property Buffer : Pointer read FBuf;
    property Size : Cardinal read FSize;
  end;

  { TWCHTTP2StrmResponseHeaderPusher }

  TWCHTTP2StrmResponseHeaderPusher = class(TWCHTTP2ResponseHeaderPusher)
  private
    FStrm : TStream;
  public
    constructor Create(aHPackEncoder : TThreadSafeHPackEncoder; aStrm : TStream);
    procedure PushHeader(const H, V : String); override;
  end;

  { TWCHTTP2Response }

  TWCHTTP2Response = class(TWCHTTP2Block)
  private
    FCurHeadersBlock : Pointer;
    FHeadersBlockSize : Longint;
    FResponsePushed  : Boolean;
  public
    constructor Create(aConnection : TWCHTTP2Connection;
                       aStream : TWCHTTP2Stream); override;
    destructor Destroy; override;
    procedure CopyFromHTTP1Response(R : TAbsHTTPConnectionResponse);
    procedure Close;
    procedure PushResponse;
    procedure SerializeResponse;
    procedure SerializeHeaders(closeStrm: Boolean);
    procedure SerializeData(closeStrm: Boolean);
    procedure SerializeResponseHeaders(R : TAbsHTTPConnectionResponse; closeStrm: Boolean);
    procedure SerializeResponseData(R : TAbsHTTPConnectionResponse; closeStrm: Boolean);
    procedure SerializeRefStream(R: TReferencedStream; closeStrm: Boolean);
    property ResponsePushed : Boolean read FResponsePushed;
  end;

  { TWCHTTP2Request }

  TWCHTTP2Request = class(TWCHTTP2Block)
  private
    FComplete : Boolean;
    FResponse : TWCHTTP2Response;
    FHeaders  : THPackHeaderTextList;
    function GetResponse: TWCHTTP2Response;
    function GetResponsePushed: Boolean;
  public
    constructor Create(aConnection : TWCHTTP2Connection;
                       aStream : TWCHTTP2Stream); override;
    destructor Destroy; override;
    function  HasData : Boolean;
    procedure CopyHeaders(aHPackDecoder : TThreadSafeHPackDecoder);
    property  Headers :  THPackHeaderTextList read FHeaders;
    property  Response : TWCHTTP2Response read GetResponse;
    property  ResponsePushed : Boolean read GetResponsePushed;
    property  Complete : Boolean read FComplete write FComplete;
  end;

  { TThreadSafeHTTP2WindowSize }

  TThreadSafeHTTP2WindowSize = class(TThreadInteger)
  private
    FBlocked    : Boolean;
    function GetBlocked: Boolean;
    function GetSize: Int32;
  public
    constructor Create(InitialSendSize : Int32);
    procedure Update(aValue : Int32);
    function Send(aValue : Int32) : Boolean;
    function Recv(aValue : Int32) : Boolean;
    procedure Block;
    procedure UnBlock;
    property Size : Int32 read GetSize;
    property Blocked : Boolean read GetBlocked;
  end;

  { TWCHTTP2IncomingChunk }

  TWCHTTP2IncomingChunk = class(TWCRequestRefWrapper)
  private
    FData    : TExtMemoryStream;
    FStream  : TWCHTTP2Stream;
    function GetConnection : TWCHTTP2Connection;
    function GetStream : TWCHTTP2Stream;
    function GetTotalSize: Int64;
  public
    constructor Create(aStream : TWCHTTP2Stream); virtual;
    destructor Destroy; override;
    function GetReqContentStream : TStream; override;
    function IsReqContentStreamOwn : Boolean; override;
    procedure Release; override;
    property TotalSize : Int64 read GetTotalSize;
    property Data : TExtMemoryStream read FData;
    procedure CopyToHTTP1Request(aReq1 : TWCConnectionRequest); override;
    procedure PushData(aBuffer: Pointer;
                       aSize: Cardinal); overload;
    property Stream : TWCHTTP2Stream read GetStream;
    property Connection : TWCHTTP2Connection read GetConnection;
  end;

  { TWCHTTP2IncomingChunks }

  TWCHTTP2IncomingChunks = class(TThreadSafeFastSeq)
  private
    FHolders : Integer;
    FTotalSize : Int64;
  public
    constructor Create;

    function  PopChunk : TWCHTTP2IncomingChunk;
    function PushChunk(aStrm : TWCHTTP2Stream; Data : Pointer; sz : Integer
      ) : TWCHTTP2IncomingChunk;

    function TotalSize : Int64;

    procedure Hold;
    procedure Release;
    function  IsReleased : Boolean;

    destructor Destroy; override;
  end;

  TWCHTTP2IncomingChunksMode = (h2icmNone, h2icmChaos, h2icmSerial);

  { TWCHTTP2Stream }

  TWCHTTP2Stream = class(TWCRequestRefWrapper)
  private
    FID : Cardinal;
    FExternalData : TObject;
    FConnection : TWCHTTP2Connection;
    FOwnExtData : Boolean;
    FStreamState : THTTP2StreamState;
    FCurRequest : TWCHTTP2Request;
    FSendWindow : TThreadSafeHTTP2WindowSize; // no recv window for streams
    FRecvWindow : TThreadSafeHTTP2WindowSize;
    FPriority : Byte;
    FRecursedPriority : ShortInt;
    FParentStream : Cardinal;
    FFinishedCode : Cardinal;
    FWaitingForContinueFrame : Boolean;
    FWaitingRemoteStream : Cardinal;
    FHeadersComplete : Boolean;
    FResponseProceed : Boolean;
    FIncomingChunks : TWCHTTP2IncomingChunks;
    FIncomingChunksMode : TWCHTTP2IncomingChunksMode;
    function GetCurResponse : TWCHTTP2Response;
    function GetExtData : TObject;
    function GetRecursedPriority: Byte;
    function GetRequestProceed : TWCHTTP2IncomingChunksMode;
    function GetResponseProceed: Boolean;
    procedure ResetRecursivePriority;
    procedure PushRequest;
    procedure SetExtData(AValue : TObject);
    procedure SetRequestProceed(AValue : TWCHTTP2IncomingChunksMode);
    procedure SetResponseProceed(AValue: Boolean);
    procedure SetWaitingForContinueFrame(AValue: Boolean);
    procedure UpdateState(Head : TWCHTTP2FrameHeader);
    procedure DoCopyToHTTP1Request(AReq: TWCConnectionRequest);
  protected
    property WaitingForContinueFrame : Boolean read FWaitingForContinueFrame write
                                         SetWaitingForContinueFrame;
    function PushData(Data : Pointer; sz : Cardinal) : Boolean;
    function PushChunk(Data : Pointer; sz : Cardinal) : Boolean;
    function FinishHeaders(aDecoder: TThreadSafeHPackDecoder): Byte;
    procedure HoldChunks;
    procedure ReleaseChunks;
    function  ChunksReleased : Boolean;
  public
    constructor Create(aConnection : TWCHTTP2Connection; aStreamID : Cardinal);
    destructor Destroy; override;
    procedure Release; override;
    procedure ResetStream(aError: Cardinal);
    property ID : Cardinal read FID;
    property StreamState : THTTP2StreamState read FStreamState;
    property ParentStream : Cardinal read FParentStream;
    property Priority :  Byte read FPriority;
    property RecursedPriority : Byte read GetRecursedPriority;
    // avaible request
    function GetReqContentStream : TStream; override;
    function IsReqContentStreamOwn : Boolean; override;

    procedure CopyToHTTP1Request(AReq : TWCConnectionRequest); override;
    function RequestReady : Boolean;
    function ChunkReady : Boolean;
    function PopRequestChunk: TWCHTTP2IncomingChunk;

    property Request : TWCHTTP2Request read FCurRequest;
    property Response : TWCHTTP2Response read GetCurResponse;
    property ResponseProceed : Boolean read GetResponseProceed write SetResponseProceed;
    property ChunkedRequest : TWCHTTP2IncomingChunksMode read GetRequestProceed
                                         write SetRequestProceed;
    property SendWindow : TThreadSafeHTTP2WindowSize read FSendWindow;

    property ExtData : TObject read GetExtData write SetExtData;
    property OwnExtData : Boolean read FOwnExtData write FOwnExtData;
  end;

  { TThreadSafeHTTP2ConnSettings }

  TThreadSafeHTTP2ConnSettings = class(TThreadSafeObject)
  private
    FConSettings : Array [1..HTTP2_SETTINGS_MAX] of Cardinal;
    function GetConnSetting(id : Word): Cardinal;
    procedure SetConnSetting(id : Word; AValue: Cardinal);
  public
    property ConnSettings[id : Word] : Cardinal read GetConnSetting write SetConnSetting; default;
  end;

  { TWCHTTP2Connection }

  TWCHTTP2Connection = class(TWCRefConnection)
  private
    FLastStreamID : Cardinal;
    FStreams : TWCHTTP2Streams;
    FConSettings : TThreadSafeHTTP2ConnSettings;
    FErrorStream : Cardinal;
    FHPackDecoder : TThreadSafeHPackDecoder;
    FHPackEncoder : TThreadSafeHPackEncoder;
    FSendWindow   : TThreadSafeHTTP2WindowSize;
    FRecvWindow   : TThreadSafeHTTP2WindowSize;

    function AddNewStream(aStreamID: Cardinal): TWCHTTP2Stream;
    function GetConnSetting(id : Word): Cardinal;
    function GetHTTP2Settings: TWCHTTP2Settings;
  protected
    procedure ResetHPack;
    procedure InitHPack;
    property  CurHPackDecoder : TThreadSafeHPackDecoder read FHPackDecoder;
    property  CurHPackEncoder : TThreadSafeHPackEncoder read FHPackEncoder;
    function GetInitialReadBufferSize : Cardinal; override;
    function GetInitialWriteBufferSize : Cardinal; override;
    function CanExpandWriteBuffer({%H-}aCurSize, {%H-}aNeedSize : Cardinal) : Boolean; override;
    function RequestsWaiting: Boolean; override;
    function NextFrameToSend(it: TIteratorObject): TIteratorObject;override;
    procedure AfterFrameSent(fr: TWCRefProtoFrame); override;
    procedure SendUpdateWindow(aStrm : TWCHTTP2Stream; aWinSize : Int32);
  public
    constructor Create(aOwner: TWCRefConnections;
        aSocket: TWCSocketReference; aOpenningMode: THTTP2OpenMode;
        aReadData, aSendData: TRefReadSendData); overload;
    class function Protocol : TWCProtocolVersion; override;
    class function CheckProtocolVersion(Data: Pointer; sz: integer): TWCProtocolVersion;
    procedure ConsumeNextFrame(Mem : TBufferedStream); override;
    destructor Destroy; override;
    procedure PushFrame(aFrameType : Byte;
                        aStream : TWCHTTP2Stream;
                        aFrameFlags : Byte;
                        aData : Pointer;
                        aDataSize : Cardinal;
                        aOwnPayload : Boolean = true); overload;
    procedure PushFrame(aFrameType : Byte;
                        aStream : TWCHTTP2Stream;
                        aFrameFlags : Byte;
                        aData : TReferencedStream;
                        aStrmPos : Int64;
                        aDataSize : Cardinal); overload;
    procedure PushFrameFront(aFrameType : Byte;
                        aStream : TWCHTTP2Stream;
                        aFrameFlags : Byte;
                        aData : Pointer;
                        aDataSize : Cardinal;
                        aOwnPayload : Boolean = true); overload;
    function PopRequestedStream : TWCHTTP2Stream;
    function PopRequestChunk: TWCHTTP2IncomingChunk;
    function TryToIdleStep(const TS : QWord) : Boolean; override;
    procedure ResetStream(aSID, aError: Cardinal);
    procedure GoAway(aError : Cardinal);
    property HTTP2Settings : TWCHTTP2Settings read GetHTTP2Settings;
    property Streams : TWCHTTP2Streams read FStreams;
    // error
    property ErrorStream : Cardinal read FErrorStream;
    //
    property ConnSettings[id : Word] : Cardinal read GetConnSetting;
  end;

  { TWCHTTP2ClosedStreams }

  TWCHTTP2ClosedStreams = class
  private
    FStartFrom, FEndAt : Cardinal;
  public
    constructor Create(SID : Cardinal);
    function Expand(SID : Cardinal) : Boolean;
    function MergeRight(n : TWCHTTP2ClosedStreams) : Boolean;
    function Contain(SID : Cardinal) : Boolean;
    property StartFrom : Cardinal read FStartFrom;
  end;

  { TWCHTTP2Streams }

  TWCHTTP2Streams = class(TThreadSafeFastSeq)
  private
    FClosedStreams : TThreadSafeFastSeq;
    procedure AddClosedStream(SID : Cardinal);
    function IsStreamClosed(aStrm: TObject; {%H-}data: pointer): Boolean;
    procedure AfterStrmExtracted(aObj : TObject);
    procedure DoCloseStream(aObj : TObject);
  public
    constructor Create;
    destructor Destroy; override;
    function  IsStreamInClosedArch(SID : Cardinal) : Boolean;
    function  GetByID(aID : Cardinal) : TWCHTTP2Stream;
    function  GetNextStreamWithRequest : TWCHTTP2Stream;
    function  PopNextRequestChunk : TWCHTTP2IncomingChunk;
    function  HasStreamWithRequest: Boolean;
    procedure CloseOldIdleStreams(aMaxId : Cardinal);
    procedure AdjustWindowSize(Delta : Int32);
    procedure RemoveClosedStreams;
    procedure CloseAll;
  end;

  { TWCHTTP2Settings }

  TWCHTTP2Settings = class(TNetCustomLockedObject)
  private
    HTTP2Settings : PHTTP2SettingsPayload;
    HTTP2SettingsSize : Cardinal;
    function GetCount: Integer;
    function GetSetting(index : integer): THTTP2SettingsBlock;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Reset;
    procedure Add(Id : Word; Value : Cardinal);
    function GetByID(Id : Word; DefaultValue : Cardinal) : Cardinal;
    function CopySettingsToMem(var Mem : Pointer) : Integer;
    property Count : Integer read GetCount;
    property Setting[index : integer] : THTTP2SettingsBlock read GetSetting; default;
  end;

  { TWCHTTP2Helper }

  TWCHTTP2Helper = class(TWCProtocolHelper)
  private
    FSettings : TWCHTTP2Settings;
  protected
    function CheckStreamID(SID : Cardinal) : Boolean; virtual; abstract;
    function CheckHeaders({%H-}Decoder : TThreadSafeHPackDecoder;
                          const {%H-}PseudoHeaders : THTTP2PseudoHeaders) : Cardinal; virtual; abstract;
    procedure ConfigureStream({%H-}aStrm : TWCHTTP2Stream); virtual; abstract;
  public
    constructor Create; override;
    destructor Destroy; override;
    property Settings : TWCHTTP2Settings read FSettings;
  end;

  { TWCHTTP2ServerHelper }

  TWCHTTP2ServerHelper = class(TWCHTTP2Helper)
  protected
    function CheckStreamID(SID : Cardinal) : Boolean; override;
    function CheckHeaders({%H-}Decoder : TThreadSafeHPackDecoder;
                          const PseudoHeaders : THTTP2PseudoHeaders) : Cardinal; override;
    procedure ConfigureStream({%H-}aStrm : TWCHTTP2Stream); override;
  end;

  { TWCHTTP2ClientHelper }

  TWCHTTP2ClientHelper = class(TWCHTTP2Helper)
  protected
    function CheckStreamID(SID : Cardinal) : Boolean; override;
    function CheckHeaders({%H-}Decoder : TThreadSafeHPackDecoder;
                          const {%H-}PseudoHeaders : THTTP2PseudoHeaders) : Cardinal; override;
    procedure ConfigureStream({%H-}aStrm : TWCHTTP2Stream); override;
  end;

implementation

const HTTP2_MAX_CHUNKS_TOTAL_SIZE = $A00000; //10 MB max buffer

{ TWCHTTP2IncomingChunk }

function TWCHTTP2IncomingChunk.GetTotalSize : Int64;
begin
  Result := Data.Size;
end;

function TWCHTTP2IncomingChunk.GetStream : TWCHTTP2Stream;
begin
  Result := FStream;
end;

function TWCHTTP2IncomingChunk.GetConnection : TWCHTTP2Connection;
begin
  Result := FStream.FConnection;
end;

constructor TWCHTTP2IncomingChunk.Create(aStream : TWCHTTP2Stream);
begin
  inherited Create;
  FStream := aStream;
  FStream.IncReference;
  FData := TExtMemoryStream.Create;
end;

destructor TWCHTTP2IncomingChunk.Destroy;
begin
  FData.Free;
  FStream.DecReference;
  inherited Destroy;
end;

function TWCHTTP2IncomingChunk.GetReqContentStream : TStream;
begin
  Result:=FData;
end;

function TWCHTTP2IncomingChunk.IsReqContentStreamOwn : Boolean;
begin
  Result:=true;
end;

procedure TWCHTTP2IncomingChunk.Release;
begin
  FStream.ReleaseChunks;
  inherited Release;
end;

procedure TWCHTTP2IncomingChunk.CopyToHTTP1Request(aReq1 : TWCConnectionRequest
  );
begin
  aReq1.Method := HTTPGETMethod;
  FStream.Lock;
  try
    FStream.DoCopyToHTTP1Request(aReq1);
  finally
    FStream.UnLock;
  end;
  aReq1.ContentLength := TotalSize;
  aReq1.WCContent.RequestRef := Self;
end;

procedure TWCHTTP2IncomingChunk.PushData(aBuffer : Pointer; aSize : Cardinal);
begin
  FData.WriteBuffer(aBuffer^, aSize);
end;

{ TWCHTTP2IncomingChunks }

constructor TWCHTTP2IncomingChunks.Create;
begin
  inherited Create;
  FHolders := 0;
  FTotalSize := 0;
end;

function TWCHTTP2IncomingChunks.PopChunk : TWCHTTP2IncomingChunk;
var
  it : TIteratorObject;
begin
  Lock;
  try
    It := ListBegin;
    if Assigned(It) then
    begin
      Hold;
      Result := TWCHTTP2IncomingChunk(It.Value);
      Dec(FTotalSize, Result.TotalSize);

      Result.DecReference;
      Extract(It);
    end else
      Result := nil;
  finally
    UnLock;
  end;
end;

function TWCHTTP2IncomingChunks.PushChunk(aStrm : TWCHTTP2Stream;
                      Data : Pointer;
                      sz : Integer) : TWCHTTP2IncomingChunk;
begin
  Lock;
  try
    if (FTotalSize + sz) > HTTP2_MAX_CHUNKS_TOTAL_SIZE then
    begin
      Result := nil;
    end else
    begin
      Result := TWCHTTP2IncomingChunk.Create(aStrm);
      Result.PushData(Data, sz);
      Inc(FTotalSize, sz);
      Push_back(Result);
    end;
  finally
    UnLock;
  end;
end;

function TWCHTTP2IncomingChunks.TotalSize : Int64;
begin
  Lock;
  try
    Result := FTotalSize;
  finally
    UnLock;
  end;
end;

procedure TWCHTTP2IncomingChunks.Hold;
begin
  Lock;
  try
    Inc(FHolders);
  finally
    UnLock;
  end;
end;

procedure TWCHTTP2IncomingChunks.Release;
begin
  Lock;
  try
    Dec(FHolders);
  finally
    UnLock;
  end;
end;

function TWCHTTP2IncomingChunks.IsReleased : Boolean;
begin
  Lock;
  try
    Result := FHolders <= 0;
  finally
    UnLock;
  end;
end;

destructor TWCHTTP2IncomingChunks.Destroy;
var P :TIteratorObject;
begin
  Lock;
  try
    P := ListBegin;
    while assigned(P) do
    begin
      TWCHTTP2IncomingChunk(P.Value).DecReference;
      P := P.Next;
    end;
    ExtractAll;
  finally
    UnLock;
  end;
  inherited Destroy;
end;

{ TWCHTTP2ClosedStreams }

constructor TWCHTTP2ClosedStreams.Create(SID : Cardinal);
begin
  FStartFrom := SID;
  FEndAt := SID;
end;

function TWCHTTP2ClosedStreams.Expand(SID : Cardinal) : Boolean;
begin
  if (Int32(SID) - Int32(FEndAt)) <= 2 then begin
    FEndAt := SID;
    Result := true;
  end else
  if (Int32(FStartFrom) - Int32(SID)) <= 2 then begin
    FStartFrom := SID;
    Result := true;
  end
  else
    Result := false;
end;

function TWCHTTP2ClosedStreams.MergeRight(n : TWCHTTP2ClosedStreams) : Boolean;
begin
  if (Int32(n.FStartFrom) - Int32(FEndAt)) <= 2 then begin
    FEndAt := n.FEndAt;
    Result := true;
  end else
    Result := false;
end;

function TWCHTTP2ClosedStreams.Contain(SID : Cardinal) : Boolean;
begin
  Result := (SID >= FStartFrom) and (SID <= FEndAt);
end;

{ TWCHTTP2ClientHelper }

function TWCHTTP2ClientHelper.CheckStreamID(SID: Cardinal): Boolean;
begin
  Result := (SID and $00000001) = 0;
end;

function TWCHTTP2ClientHelper.CheckHeaders(
  Decoder: TThreadSafeHPackDecoder; const PseudoHeaders: THTTP2PseudoHeaders
  ): Cardinal;
begin
  Result := H2E_NO_ERROR;
end;

procedure TWCHTTP2ClientHelper.ConfigureStream(aStrm : TWCHTTP2Stream);
begin
  //do nothing
end;

{ TWCHTTP2ServerHelper }

function TWCHTTP2ServerHelper.CheckStreamID(SID: Cardinal): Boolean;
begin
  Result := (SID and $00000001) > 0;
end;

function TWCHTTP2ServerHelper.CheckHeaders(
  {%H-}Decoder: TThreadSafeHPackDecoder; const PseudoHeaders: THTTP2PseudoHeaders
  ): Cardinal;
begin
  // server-specific check
  if Length(PseudoHeaders[hh2Status]) > 0 then
    Exit(H2E_PROTOCOL_ERROR);
  if (Length(PseudoHeaders[hh2Path]) = 0) and
      (SameStr(PseudoHeaders[hh2Scheme], 'http') or
       SameStr(PseudoHeaders[hh2Scheme], 'https')) then
    Exit(H2E_PROTOCOL_ERROR);
  if (Length(PseudoHeaders[hh2Scheme]) = 0) then
    Exit(H2E_PROTOCOL_ERROR);
  Exit(H2E_NO_ERROR);
end;

procedure TWCHTTP2ServerHelper.ConfigureStream(aStrm : TWCHTTP2Stream);
begin
  //do nothing
end;

{ TWCHTTP2Helper }

constructor TWCHTTP2Helper.Create;
begin
  inherited Create(wcHTTP2);
  FSettings := TWCHTTP2Settings.Create;
end;

destructor TWCHTTP2Helper.Destroy;
begin
  FSettings.Free;
  inherited Destroy;
end;

{ TThreadSafeHTTP2WindowSize }

function TThreadSafeHTTP2WindowSize.GetSize: Int32;
begin
  Result := Value;
end;

function TThreadSafeHTTP2WindowSize.GetBlocked: Boolean;
begin
  Lock;
  try
    Result := FBlocked;
  finally
    UnLock;
  end;
end;

constructor TThreadSafeHTTP2WindowSize.Create(InitialSendSize: Int32);
begin
  inherited Create(InitialSendSize);
  FBlocked := false;
end;

procedure TThreadSafeHTTP2WindowSize.Update(aValue: Int32);
begin
  Lock;
  try
    IncValue(aValue);
    if Value > 0 then FBlocked := false;
  finally
    UnLock;
  end;
end;

function TThreadSafeHTTP2WindowSize.Send(aValue: Int32): Boolean;
begin
  Lock;
  try
    if Value >= aValue then
    begin
      DecValue(aValue);
      Result := true;
    end else
      Result := false;
  finally
    UnLock;
  end;
end;

function TThreadSafeHTTP2WindowSize.Recv(aValue : Int32) : Boolean;
begin
  Lock;
  try
    if Value >= aValue then
    begin
      DecValue(aValue);
      if Value = 0 then FBlocked:=true;
      Result := true;
    end else
      Result := false;
  finally
    UnLock;
  end;
end;

procedure TThreadSafeHTTP2WindowSize.Block;
begin
  Lock;
  try
    FBlocked:=true;
  finally
    UnLock;
  end;
end;

procedure TThreadSafeHTTP2WindowSize.UnBlock;
begin
  Lock;
  try
    FBlocked:=false;
  finally
    UnLock;
  end;
end;

{ TWCHTTP2Settings }

function TWCHTTP2Settings.GetCount: Integer;
begin
  Lock;
  try
    Result := HTTP2SettingsSize div H2P_SETTINGS_BLOCK_SIZE;
  finally
    UnLock;
  end;
end;

function TWCHTTP2Settings.GetSetting(index : integer
  ): THTTP2SettingsBlock;
begin
  Lock;
  try
    Result := HTTP2Settings^[index];
  finally
    UnLock;
  end;
end;

constructor TWCHTTP2Settings.Create;
begin
  inherited Create;
  HTTP2Settings := nil;
  HTTP2SettingsSize := 0;
end;

destructor TWCHTTP2Settings.Destroy;
begin
  if assigned(HTTP2Settings) then Freemem(HTTP2Settings);
  inherited Destroy;
end;

procedure TWCHTTP2Settings.Reset;
begin
  Lock;
  try
    if assigned(HTTP2Settings) then FreeMem(HTTP2Settings);
    HTTP2Settings := GetMem(HTTP2_SETTINGS_MAX_SIZE);
    HTTP2SettingsSize := 0;
  finally
    UnLock;
  end;
end;

procedure TWCHTTP2Settings.Add(Id: Word; Value: Cardinal);
var l, Sz : Integer;
    S : PHTTP2SettingsPayload;
begin
  Lock;
  try
    if not Assigned(HTTP2Settings) then
      Reset;
    S := HTTP2Settings;
    Sz := HTTP2SettingsSize div H2P_SETTINGS_BLOCK_SIZE;
    for l := 0 to Sz - 1 do
    begin
      if S^[l].Identifier = Id then begin
        S^[l].Value := Value;
        Exit;
      end;
    end;
    if HTTP2SettingsSize < HTTP2_SETTINGS_MAX_SIZE then
    begin
      S^[Sz].Identifier := Id;
      S^[Sz].Value := Value;
      Inc(HTTP2SettingsSize, H2P_SETTINGS_BLOCK_SIZE);
    end;
  finally
    UnLock;
  end;
end;

function TWCHTTP2Settings.GetByID(Id: Word; DefaultValue: Cardinal
  ): Cardinal;
var l, Sz : Integer;
    S : PHTTP2SettingsPayload;
begin
  Result := DefaultValue;
  Lock;
  try
    S := HTTP2Settings;
    Sz := HTTP2SettingsSize div H2P_SETTINGS_BLOCK_SIZE;
    for l := 0 to Sz - 1 do
    begin
      if S^[l].Identifier = Id then begin
        Result := S^[l].Value;
        Exit;
      end;
    end;
  finally
    UnLock;
  end;
end;

function TWCHTTP2Settings.CopySettingsToMem(var Mem: Pointer): Integer;
begin
  Lock;
  try
    Result := HTTP2SettingsSize;
    if HTTP2SettingsSize > 0 then
    begin
      Mem := GetMem(HTTP2SettingsSize);
      Move(HTTP2Settings^, Mem^, HTTP2SettingsSize);
    end else Mem := nil;
  finally
    UnLock;
  end;
end;

{ TThreadSafeHTTP2ConnSettings }

function TThreadSafeHTTP2ConnSettings.GetConnSetting(id : Word): Cardinal;
begin
  lock;
  try
    Result := FConSettings[id];
  finally
    UnLock;
  end;
end;

procedure TThreadSafeHTTP2ConnSettings.SetConnSetting(id : Word; AValue: Cardinal);
begin
  lock;
  try
    FConSettings[id] := AValue;
  finally
    UnLock;
  end;
end;

{ TThreadSafeHPackEncoder }

constructor TThreadSafeHPackEncoder.Create(TableSize: Cardinal);
begin
  inherited Create;
  FEncoder := THPackEncoder.Create(TableSize);
end;

destructor TThreadSafeHPackEncoder.Destroy;
begin
  FEncoder.Free;
  inherited Destroy;
end;

procedure TThreadSafeHPackEncoder.EncodeHeader(aOutStream: TStream;
  const aName: RawByteString; const aValue: RawByteString;
  const aSensitive: Boolean);
begin
  Lock;
  try
    FEncoder.EncodeHeader(aOutStream, aName, aValue, aSensitive);
  finally
    UnLock;
  end;
end;

{ TThreadSafeHPackDecoder }

function TThreadSafeHPackDecoder.GetDecodedHeaders: THPackHeaderTextList;
begin
  Lock;
  try
    Result := FDecoder.DecodedHeaders;
  finally
    UnLock;
  end;
end;

constructor TThreadSafeHPackDecoder.Create(HeadersListSize, TableSize: Cardinal
  );
begin
  Inherited Create;
  FDecoder := THPackDecoder.Create(HeadersListSize, TableSize);
end;

destructor TThreadSafeHPackDecoder.Destroy;
begin
  FDecoder.Free;
  inherited Destroy;
end;

procedure TThreadSafeHPackDecoder.Decode(aStream: TStream);
begin
  Lock;
  try
    FDecoder.Decode(aStream);
  finally
    UnLock;
  end;
end;

function TThreadSafeHPackDecoder.Malformed: Boolean;
begin
  Lock;
  try
    Result := FDecoder.EndHeaderBlockTruncated;
    if not Result then
    begin
      Result := FDecoder.DecodedHeaders.Count = 0;
    end;
  finally
    UnLock;
  end;
end;

{ TWCHTTP2UpgradeResponseFrame }

constructor TWCHTTP2UpgradeResponseFrame.Create(Mode: THTTP2OpenMode);
begin
  FMode:= Mode;
end;

procedure TWCHTTP2UpgradeResponseFrame.SaveToStream(Str: TStream);
var Buffer : Pointer;
    BufferSize : Cardinal;
begin
  case FMode of
    h2oUpgradeToH2C : begin
      Buffer := @(HTTP2UpgradeBlockH2C[1]);
      BufferSize:= HTTP2UpgradeBlockH2CSize;
    end;
    h2oUpgradeToH2 : begin
      Buffer := @(HTTP2UpgradeBlockH2[1]);
      BufferSize:= HTTP2UpgradeBlockH2Size;
    end;
  else
    Buffer := nil;
    BufferSize := 0;
  end;
  if assigned(Buffer) then
    Str.WriteBuffer(Buffer^, BufferSize);
end;

function TWCHTTP2UpgradeResponseFrame.Memory : Pointer;
begin
  case FMode of
    h2oUpgradeToH2C : begin
      Result := @(HTTP2UpgradeBlockH2C[1]);
    end;
    h2oUpgradeToH2 : begin
      Result := @(HTTP2UpgradeBlockH2[1]);
    end;
  else
    Result := nil;
  end;
end;

function TWCHTTP2UpgradeResponseFrame.Size: Int64;
begin
  case FMode of
    h2oUpgradeToH2C : begin
      Result:= HTTP2UpgradeBlockH2CSize;
    end;
    h2oUpgradeToH2 : begin
      Result:= HTTP2UpgradeBlockH2Size;
    end;
  else
    Result := 0;
  end;
end;

{ TWCHTTP2AdvFrame }

procedure TWCHTTP2AdvFrame.SaveToStream(Str: TStream);
begin
  Str.WriteBuffer(HTTP2Preface, H2P_PREFACE_SIZE);
end;

function TWCHTTP2AdvFrame.Memory : Pointer;
begin
  Result := @(HTTP2Preface[0]);
end;

function TWCHTTP2AdvFrame.Size: Int64;
begin
  Result := H2P_PREFACE_SIZE;
end;

{ TWCHTTP2StrmResponseHeaderPusher }

constructor TWCHTTP2StrmResponseHeaderPusher.Create(
  aHPackEncoder: TThreadSafeHPackEncoder; aStrm: TStream);
begin
  inherited Create(aHPackEncoder);
  FStrm := aStrm;
end;

procedure TWCHTTP2StrmResponseHeaderPusher.PushHeader(const H, V: String);
begin
  FMem.Position:=0;
  FHPackEncoder.EncodeHeader(FMem, H, V, false);
  FStrm.WriteBuffer(FMem.Memory^, FMem.Position);
end;

{ TWCHTTP2BufResponseHeaderPusher }

constructor TWCHTTP2BufResponseHeaderPusher.Create(
  aHPackEncoder: TThreadSafeHPackEncoder; aBuffer: Pointer; aBufferSize,
  aBufGrowValue: Cardinal);
begin
  inherited Create(aHPackEncoder);
  FBuf := aBuffer;
  FCapacity:= aBufferSize;
  FBufGrowValue := aBufGrowValue;
  FSize := 0;
end;

procedure TWCHTTP2BufResponseHeaderPusher.PushHeader(const H, V: String);

procedure ExpandHeadersBuffer;
begin
  FCapacity := FCapacity + FBufGrowValue;
  FBuf := ReAllocMem(FBuf, FCapacity);
end;

begin
  FMem.Position:=0;
  FHPackEncoder.EncodeHeader(FMem, H, V, false);
  if FMem.Position + FSize > FCapacity then
    ExpandHeadersBuffer;
  Move(FMem.Memory^, PByte(FBuf)[FSize], FMem.Position);
  Inc(FSize, FMem.Position);
end;

{ TWCHTTP2ResponseHeaderPusher }

constructor TWCHTTP2ResponseHeaderPusher.Create(
  aHPackEncoder: TThreadSafeHPackEncoder);
begin
  aHPackEncoder.IncReference;
  FHPackEncoder := aHPackEncoder;
  FMem := TExtMemoryStream.Create(4128);
end;

destructor TWCHTTP2ResponseHeaderPusher.Destroy;
begin
  FHPackEncoder.DecReference;
  FMem.Free;
  inherited Destroy;
end;

procedure TWCHTTP2ResponseHeaderPusher.PushAll(R: TAbsHTTPConnectionResponse);
var h1 : THeader;
    h2 : THTTP2Header;
    v  : String;
    i : integer;
begin
  FHPackEncoder.Lock;
  try
    PushHeader(HTTP2HeaderStatus, Inttostr(R.Code));
    //PushHeader(HTTP2HeaderVersion, HTTP2VersionId);
    h1 := hhUnknown;
    while h1 < High(THeader) do
    begin
      Inc(h1);
      if R.HeaderIsSet(h1) then
        PushHeader(LowerCase(HTTPHeaderNames[h1]), R.GetHeader(h1));
    end;
    h2 := hh2Status;
    while h2 < High(THTTP2Header) do
    begin
      inc(h2);
      v := R.GetCustomHeader(HTTP2AddHeaderNames[h2]);
      if Length(v) > 0 then
         PushHeader(HTTP2AddHeaderNames[h2], v);
    end;
    for i := 0 to R.Cookies.Count-1 do
      PushHeader(LowerCase(HTTP2AddHeaderNames[hh2SetCookie]),
                                                    R.Cookies[i].AsString);
  finally
    FHPackEncoder.UnLock;
  end;
end;

{ TWCHTTP2SerializeStream }

constructor TWCHTTP2SerializeStream.Create(aConn: TWCHTTP2Connection;
  aStrm: TWCHTTP2Stream; aFirstFrameType: Byte; aNextFramesType: Byte; aFlags,
  aFinalFlags: Byte);
begin
  Inherited Create;
  FStream := aStrm;
  if assigned(FStream) then FStream.IncReference;
  FConn := aConn;
  FConn.IncReference;
  FFlags := aFlags;
  FFinalFlags := aFinalFlags;
  FFirstFrameType:= aFirstFrameType;
  FNextFramesType:= aNextFramesType;
  FCurFrame := nil;
  FRestFrameSz := 0;
  FChunked := false;
  FFirstFramePushed := false;
end;

function TWCHTTP2SerializeStream.Write(const Buffer; Count: Longint): Longint;
var B, Src : Pointer;
    Sz, BSz, MaxSize : Longint;
begin
  Src := @Buffer;
  Result := Count;
  Sz := Count;
  MaxSize := FConn.ConnSettings[H2SET_MAX_FRAME_SIZE];
  if FFirstFrameType in HTTP2_FLOW_CONTROL_FRAME_TYPES then
  begin
    if FConn.FSendWindow.Size < MaxSize then
      MaxSize := FConn.FSendWindow.Size;
    if Assigned(FStream) then
    begin
      if (FStream.FSendWindow.Size < MaxSize) then
        MaxSize := FStream.FSendWindow.Size;
    end;
    if MaxSize < HTTP2_MIN_MAX_FRAME_SIZE then
       MaxSize := HTTP2_MIN_MAX_FRAME_SIZE;
  end;
  if (Sz > MaxSize) and (FChunked) then
     Exit(-1);
  while Sz > 0 do begin
    if Assigned(FCurFrame) and
       ((FRestFrameSz = 0) or
        (FChunked and (FRestFrameSz < Sz))) then
    begin
      FConn.PushFrame(FCurFrame);
      FCurFrame := nil;
    end;

    if not Assigned(FCurFrame) then
    begin
      if Sz > MaxSize then Bsz := MaxSize else Bsz := Sz;
      FRestFrameSz := MaxSize - Bsz;
      B := GetMem(MaxSize);
      if FFirstFramePushed then
        FCurFrame := TWCHTTP2DataFrame.Create(FNextFramesType, FStream, FFlags, B, Bsz)
      else begin
        FCurFrame := TWCHTTP2DataFrame.Create(FFirstFrameType, FStream, FFlags, B, Bsz);
        FFirstFramePushed:= true;
      end;
    end else
    begin
      BSz := Sz;
      if BSz > FRestFrameSz then
      begin
         BSz := FRestFrameSz;
         FRestFrameSz := 0;
      end else
         Dec(FRestFrameSz, BSz);
      B := Pointer(@(PByte(FCurFrame.Payload)[FCurFrame.Header.PayloadLength]));
      Inc(FCurFrame.Header.PayloadLength, Bsz);
    end;
    Move(Src^, B^, BSz);
    Inc(Src, BSz);
    Dec(Sz, BSz);
  end;
end;

procedure TWCHTTP2SerializeStream.Flush;
begin
  if assigned(FCurFrame) then begin
    FCurFrame.Header.FrameFlag := FFinalFlags;
    FConn.PushFrame(FCurFrame);
    FCurFrame := nil;
  end;
end;

destructor TWCHTTP2SerializeStream.Destroy;
begin
  Flush();
  if Assigned(FStream) then FStream.DecReference;
  FConn.DecReference;
  inherited Destroy;
end;

{ TWCHTTP2Response }

constructor TWCHTTP2Response.Create(aConnection: TWCHTTP2Connection;
  aStream: TWCHTTP2Stream);
begin
  inherited Create(aConnection, aStream);
  FResponsePushed := false;
  FCurHeadersBlock:= nil;
end;

destructor TWCHTTP2Response.Destroy;
begin
  if assigned(FCurHeadersBlock) then FreeMemAndNil(FCurHeadersBlock);
  inherited Destroy;
end;

procedure TWCHTTP2Response.CopyFromHTTP1Response(R: TAbsHTTPConnectionResponse);
var pusher : TWCHTTP2BufResponseHeaderPusher;
    Capacity : Cardinal;
begin
  Capacity := FConnection.ConnSettings[H2SET_MAX_FRAME_SIZE];
  FCurHeadersBlock := ReAllocMem(FCurHeadersBlock, Capacity);
  FHeadersBlockSize:=0;
  FConnection.InitHPack;
  pusher := TWCHTTP2BufResponseHeaderPusher.Create(FConnection.CurHPackEncoder,
                                                   FCurHeadersBlock,
                                                   Capacity,
                                                   Capacity);
  try
    pusher.pushall(R);
    FCurHeadersBlock := pusher.Buffer;
    FHeadersBlockSize:= pusher.Size;
  finally
    pusher.Free;
  end;
end;

procedure TWCHTTP2Response.Close;
//var er : PHTTP2RstStreamPayload;
begin
  FConnection.PushFrame(H2FT_DATA, FStream, H2FL_END_STREAM, nil, 0);
  {er := GetMem(H2P_RST_STREAM_FRAME_SIZE);
  er^.ErrorCode := H2E_NO_ERROR;
  FConnection.PushFrame(H2FT_RST_STREAM, FStream.ID, 0, er, H2P_RST_STREAM_FRAME_SIZE); }
end;

procedure TWCHTTP2Response.PushResponse;
begin
  FResponsePushed := true;
end;

procedure TWCHTTP2Response.SerializeResponse;
begin
  SerializeHeaders(DataBlockSize = 0);
  if DataBlockSize > 0 then
     SerializeData(true);
end;

procedure TWCHTTP2Response.SerializeHeaders(closeStrm : Boolean);
var
  sc : TWCHTTP2SerializeStream;
begin
  if Assigned(FCurHeadersBlock) then
  begin
    sc := TWCHTTP2SerializeStream.Create(FConnection, FStream,
                                         H2FT_HEADERS,
                                         H2FT_CONTINUATION,
                                         0,
                                         H2FL_END_HEADERS or
                                         (Ord(closeStrm) * H2FL_END_STREAM));
    try
      sc.WriteBuffer(FCurHeadersBlock^, FHeadersBlockSize);
      sc.Flush;
    finally
      sc.Free;
    end;
    FreeMemAndNil(FCurHeadersBlock);
    FHeadersBlockSize:=0;
    if closeStrm then
      PushResponse;
  end;
end;

procedure TWCHTTP2Response.SerializeData(closeStrm : Boolean);
var
  sc : TWCHTTP2SerializeStream;
begin
  // serialize in group of data Chunk with max_frame_size
  // then remove fdatablock
  if (DataBlockSize > 0) then
  begin
    sc := TWCHTTP2SerializeStream.Create(FConnection, FStream,
                                         H2FT_DATA,
                                         H2FT_DATA,
                                         0,
                                         (Ord(closeStrm) * H2FL_END_STREAM));
    try
      sc.WriteBuffer(FData.Memory^, DataBlockSize);
      sc.Flush;
    finally
      sc.Free;
    end;
    if closeStrm then
      PushResponse;
  end;
  FData.Clear;
end;

procedure TWCHTTP2Response.SerializeResponseHeaders(R: TAbsHTTPConnectionResponse;
  closeStrm: Boolean);
var sc : TWCHTTP2SerializeStream;
    pusher : TWCHTTP2StrmResponseHeaderPusher;
begin
  if Assigned(FCurHeadersBlock) then FreeMemAndNil(FCurHeadersBlock);
  FHeadersBlockSize:=0;

  sc := TWCHTTP2SerializeStream.Create(FConnection,
                                       FStream,
                                       H2FT_HEADERS,
                                       H2FT_CONTINUATION,
                                       0,
                                       H2FL_END_HEADERS or
                                       (Ord(closeStrm) * H2FL_END_STREAM));
  FConnection.InitHPack;
  FConnection.CurHPackEncoder.Lock;  // should block encoder here cause of GOAWAY(9) error
  try
    pusher := TWCHTTP2StrmResponseHeaderPusher.Create(FConnection.CurHPackEncoder,
                                                      sc);
    try
      sc.Chunked := true;
      pusher.PushAll(R);
      sc.Flush;
      if closeStrm then
        PushResponse;
    finally
      sc.Free;
      pusher.Free;
    end;
  finally
    FConnection.CurHPackEncoder.UnLock;
  end;
end;

procedure TWCHTTP2Response.SerializeResponseData(R: TAbsHTTPConnectionResponse;
  closeStrm: Boolean);
var sc : TWCHTTP2SerializeStream;
begin
  FData.Clear;

  if R.ContentLength > 0 then
  begin
    sc := TWCHTTP2SerializeStream.Create(FConnection, FStream,
                                         H2FT_DATA,
                                         H2FT_DATA,
                                         0,
                                         (Ord(closeStrm) * H2FL_END_STREAM));
    try
      if assigned(R.ContentStream) then
      begin
        sc.CopyFrom(R.ContentStream, R.ContentStream.Size);
        sc.Flush;
      end else
      begin
        R.Contents.SaveToStream(sc);
      end;
      if closeStrm then
        PushResponse;
    finally
      sc.Free;
    end;
  end;
end;

procedure TWCHTTP2Response.SerializeRefStream(R: TReferencedStream;
  closeStrm: Boolean);
var BSz, MaxSize : Longint;
    CurFrame : TWCHTTP2RefFrame;
    Pos, Size : Int64;
begin
  R.IncReference;
  try
    Pos := 0;
    Size := R.Stream.Size;
    CurFrame := nil;
    MaxSize := FConnection.ConnSettings[H2SET_MAX_FRAME_SIZE];
    if FConnection.FSendWindow.Size < MaxSize then
      MaxSize := FConnection.FSendWindow.Size;
    if Assigned(FStream) then
    begin
      if (FStream.FSendWindow.Size < MaxSize) then
        MaxSize := FStream.FSendWindow.Size;
    end;
    if MaxSize < HTTP2_MIN_MAX_FRAME_SIZE then
       MaxSize := HTTP2_MIN_MAX_FRAME_SIZE;
    while Size > 0 do begin
      if Assigned(CurFrame) then
      begin
        FConnection.PushFrame(CurFrame);
        CurFrame := nil;
      end;
      if Size > MaxSize then Bsz := MaxSize else Bsz := Size;
      CurFrame := TWCHTTP2RefFrame.Create(H2FT_DATA, FStream, 0, R, Pos, Bsz);
      Inc(Pos, BSz);
      Dec(Size, BSz);
    end;
    if assigned(CurFrame) then begin
      if closeStrm then
        CurFrame.Header.FrameFlag := H2FL_END_STREAM;
      FConnection.PushFrame(CurFrame);
    end;
    if closeStrm then
      PushResponse;
  finally
    R.DecReference;
  end;
end;

{ TWCHTTP2Request }

function TWCHTTP2Request.GetResponse: TWCHTTP2Response;
begin
  if Assigned(FResponse) then Exit(FResponse);
  FResponse := TWCHTTP2Response.Create(FConnection, FStream);
  Result := FResponse;
end;

function TWCHTTP2Request.GetResponsePushed: Boolean;
begin
  if Assigned(FResponse) then
  begin
    Result := FResponse.ResponsePushed;
  end else Result := false;
end;

constructor TWCHTTP2Request.Create(aConnection : TWCHTTP2Connection;
                                   aStream : TWCHTTP2Stream);
begin
  inherited Create(aConnection, aStream);
  FComplete := false;
  FResponse := nil;
  FHeaders  := THPackHeaderTextList.Create;
end;

destructor TWCHTTP2Request.Destroy;
begin
  if assigned(FResponse) then FreeAndNil(FResponse);
  FHeaders.Free;
  inherited Destroy;
end;

function TWCHTTP2Request.HasData : Boolean;
begin
  Result := DataBlockSize > 0;
end;

procedure TWCHTTP2Request.CopyHeaders(aHPackDecoder: TThreadSafeHPackDecoder);
var i : integer;
    p : PHPackHeaderTextItem;
begin
  aHPackDecoder.IncReference;
  aHPackDecoder.Lock;
  try
    FHeaders.Clear;
    for i := 0 to aHPackDecoder.DecodedHeaders.Count-1 do
    begin
      P := aHPackDecoder.DecodedHeaders[i];
      FHeaders.Add(P^.HeaderName, P^.HeaderValue, P^.IsSensitive);
    end;
    aHPackDecoder.DecodedHeaders.Clear;
  finally
    aHPackDecoder.UnLock;
    aHPackDecoder.DecReference;
  end;
end;
  
{ TWCHTTP2Frame }

constructor TWCHTTP2Frame.Create(aFrameType: Byte;
  aStr: TWCHTTP2Stream;
  aFrameFlags: Byte);
begin
  Header := TWCHTTP2FrameHeader.Create;
  Header.FrameType := aFrameType;
  Header.FrameFlag := aFrameFlags;
  Header.PayloadLength := 0;
  Stream := aStr;
  if assigned(Stream) then
  begin
    Stream.IncReference;
    Header.StreamID := Stream.ID;
  end else
    Header.StreamID := 0;
end;
                     
destructor TWCHTTP2Frame.Destroy;
begin
  Header.Free;
  if assigned(Stream) then Stream.DecReference;
  inherited Destroy;
end;
                     
procedure TWCHTTP2Frame.SaveToStream(Str : TStream);
begin
  Header.SaveToStream(Str);
end;

function TWCHTTP2Frame.Memory : Pointer;
begin
  Result := nil;
end;

function TWCHTTP2Frame.Size: Int64;
begin
  Result := H2P_FRAME_HEADER_SIZE + Header.PayloadLength;
end;

{ TWCHTTP2DataFrame }

constructor TWCHTTP2DataFrame.Create(aFrameType: Byte; aStream: TWCHTTP2Stream;
  aFrameFlags: Byte; aData: Pointer; aDataSize: Cardinal; aOwnPayload: Boolean);
begin
  inherited Create(aFrameType, aStream, aFrameFlags);
  Header.PayloadLength := aDataSize;
  Payload:= aData;
  OwnPayload:= aOwnPayload;
end;

function TWCHTTP2DataFrame.Memory : Pointer;
begin
  Result := Payload;
end;

destructor TWCHTTP2DataFrame.Destroy;
begin
  if Assigned(Payload) and OwnPayload then Freemem(Payload);
  inherited Destroy;
end;

procedure TWCHTTP2DataFrame.SaveToStream(Str: TStream);
begin
  inherited SaveToStream(Str);
  if Header.PayloadLength > 0 then
    Str.Write(Payload^, Header.PayloadLength);
end;

{ TWCHTTP2RefFrame }

constructor TWCHTTP2RefFrame.Create(aFrameType: Byte; aStream: TWCHTTP2Stream;
  aFrameFlags: Byte; aData: TReferencedStream; aStrmPos: Int64;
  aDataSize: Cardinal);
begin
  inherited Create(aFrameType, aStream, aFrameFlags);
  Header.PayloadLength := aDataSize;
  aData.IncReference;
  FStrm := aData;
  Fpos:= aStrmPos;
end;

function TWCHTTP2RefFrame.Memory : Pointer;
begin
  if FStrm.Stream is TCustomMemoryStream then
    Result := TCustomMemoryStream(FStrm.Stream).Memory
  else
    Result := nil;
end;

destructor TWCHTTP2RefFrame.Destroy;
begin
  FStrm.DecReference;
  inherited Destroy;
end;

procedure TWCHTTP2RefFrame.SaveToStream(Str: TStream);
begin
  inherited SaveToStream(Str);
  if Header.PayloadLength > 0 then
    FStrm.WriteTo(Str, Fpos, Header.PayloadLength)
end;

{ TWCHTTP2FrameHeader }

procedure TWCHTTP2FrameHeader.LoadFromStream(Str: TStream);
var FrameHeader : Array [0..H2P_FRAME_HEADER_SIZE-1] of Byte;
begin
  // read header
  Str.Read(FrameHeader, H2P_FRAME_HEADER_SIZE);
  // format frame
  PayloadLength := (FrameHeader[0] shl 16) or
                   (FrameHeader[1] shl 8) or
                    FrameHeader[2];
  FrameType:= FrameHeader[3];
  FrameFlag:= FrameHeader[4];
  StreamID := BEtoN(PCardinal(@(FrameHeader[5]))^) and H2P_STREAM_ID_MASK;
end;

procedure TWCHTTP2FrameHeader.SaveToStream(Str: TStream);
var FrameHeader : Array [0..H2P_FRAME_HEADER_SIZE-1] of Byte;
    PL24 : Cardinal;
begin
  // format frame
  // 0x00a2b3c4 << 8 --> 0xa2b3c400 (0x00c4b3a2 in LE)
  // NtoBE(0x00c4b3a2) --> 0xa2b3c400
  PL24 := PayloadLength shl 8;
  // write first most significant 3 bytes
  Move(NtoBE(PL24), FrameHeader[0], H2P_PAYLOAD_LEN_SIZE);
  FrameHeader[3] := FrameType;
  FrameHeader[4] := FrameFlag;
  Move(NtoBE(StreamID), FrameHeader[5], H2P_STREAM_ID_SIZE);

  // write header
  Str.Write(FrameHeader, H2P_FRAME_HEADER_SIZE);
end;

{ TWCHTTP2Block }

procedure TWCHTTP2Block.PushData(aData: Pointer; sz: Cardinal);
var cursize : int64;
begin
  if sz = 0 then Exit;

  cursize := FData.Size;
  FData.Size := cursize + sz;

  Move(aData^, PByte(FData.Memory)[cursize], Sz);
end;

procedure TWCHTTP2Block.PushData(Strm: TStream; startAt : Int64);
var sz : Int64;
    cursize : int64;
begin
  Strm.Position:= startAt;
  sz := Strm.Size - startAt;
  if Sz > 0 then
  begin
    cursize := FData.Size;
    FData.Size := cursize + sz;

    Strm.Read(PByte(FData.Memory)[cursize], Sz);
  end;
end;

procedure TWCHTTP2Block.PushData(Strings: TStrings);
var ToSend : String;
    L : LongInt;
begin
  ToSend := Strings.Text;
  L := Length(ToSend);
  PushData(Pointer(@(ToSend[1])), L);
end;

procedure TWCHTTP2Block.Clean;
begin
  FData.Size := 0;
end;

function TWCHTTP2Block.GetDataBlock : TExtMemoryStream;
begin
  Result := FData;
end;

function TWCHTTP2Block.GetDataBlockSize : Integer;
begin
  Result := FData.Size;
end;

constructor TWCHTTP2Block.Create(aConnection: TWCHTTP2Connection;
  aStream: TWCHTTP2Stream);
begin
  FData := TExtMemoryStream.Create;
  FConnection := aConnection;
  FStream := aStream;
end;

destructor TWCHTTP2Block.Destroy;
begin
  FreeAndNil(FData);
  inherited Destroy;
end;

{ TWCHTTP2Connection }

function TWCHTTP2Connection.AddNewStream(aStreamID : Cardinal): TWCHTTP2Stream;
{$IFDEF DEBUG_STAT}
var R : Integer;
{$ENDIF}
begin
  {$IFDEF DEBUG_STAT}
  R := FStreams.Count;
  if R > DEBUG_GLOBALS_LONGWORD[DG_MAX_CONCURRENT_STREAMS] then
     DEBUG_GLOBALS_LONGWORD[DG_MAX_CONCURRENT_STREAMS] := R;
  {$ENDIF}
  Result := TWCHTTP2Stream.Create(Self, aStreamID);
  FStreams.Push_back(Result);
  Owner.GarbageCollector.Add(Result);
end;

function TWCHTTP2Connection.GetConnSetting(id : Word): Cardinal;
begin
  Result := FConSettings[id];
end;

function TWCHTTP2Connection.GetHTTP2Settings: TWCHTTP2Settings;
begin
  Result := TWCHTTP2Helper(Owner.Protocol[wcHTTP2]).Settings;
end;

constructor TWCHTTP2Connection.Create(aOwner: TWCRefConnections;
  aSocket: TWCSocketReference; aOpenningMode: THTTP2OpenMode;
  aReadData, aSendData: TRefReadSendData);
var i, Sz : integer;
    CSet : PHTTP2SettingsPayload;
begin
  inherited Create(aOwner, aSocket, aReadData, aSendData);
  FStreams := TWCHTTP2Streams.Create;
  FLastStreamID := 0;
  FConSettings := TThreadSafeHTTP2ConnSettings.Create;
  for i := 1 to HTTP2_SETTINGS_MAX do
    FConSettings[i] := HTTP2_SET_INITIAL_VALUES[i];
  HTTP2Settings.Lock;
  try
    with HTTP2Settings do
    for i := 0 to Count-1 do
    begin
      FConSettings[Setting[i].Identifier] := Setting[i].Value;
    end;
  finally
    HTTP2Settings.UnLock;
  end;
  InitializeBuffers;
  FSendWindow := TThreadSafeHTTP2WindowSize.Create(FConSettings[H2SET_INITIAL_WINDOW_SIZE]);
  FRecvWindow := TThreadSafeHTTP2WindowSize.Create(FConSettings[H2SET_INITIAL_WINDOW_SIZE]);
  // send initial settings frame
  if aOpenningMode in [h2oUpgradeToH2C, h2oUpgradeToH2] then
    PushFrame(TWCHTTP2UpgradeResponseFrame.Create(aOpenningMode));
  Sz := HTTP2Settings.CopySettingsToMem(Cset);
  PushFrame(TWCHTTP2DataFrame.Create(H2FT_SETTINGS, nil, 0, CSet,  Sz));
end;

class function TWCHTTP2Connection.Protocol: TWCProtocolVersion;
begin
  Result := wcHTTP2;
end;

class function TWCHTTP2Connection.CheckProtocolVersion(Data : Pointer;
  sz : integer) : TWCProtocolVersion;
begin
  if sz >= H2P_PREFACE_SIZE then
  begin
    if CompareByte(Data^, HTTP2Preface[0], H2P_PREFACE_SIZE) = 0 then
    begin
      Result:=wcHTTP2;
    end else
    begin
      if (PByteArray(Data)^[0] in HTTP1HeadersAllowed) then
        Result:=wcHTTP1 else
        Result:=wcUNK; // other protocol
    end;
  end else Result:= wcUNK;
end;

procedure TWCHTTP2Connection.ConsumeNextFrame(Mem: TBufferedStream);
var
  Sz, fallbackpos : Int64;
  err : Byte;
  Buffer : Pointer;
  FrameHeader : TWCHTTP2FrameHeader;
  S : TBufferedStream;
  Str, RemoteStr : TWCHTTP2Stream;

function ProceedHeadersPayload(Strm : TWCHTTP2Stream; aSz : Integer) : Byte;
var readbuf : TBufferedStream;
    aDecoder : TThreadSafeHPackDecoder;
begin
  if aSz <= 0 then Result := H2E_PROTOCOL_ERROR;
  Result := H2E_NO_ERROR;
  //hpack here
  InitHPack;
  aDecoder := CurHPackDecoder;
  aDecoder.IncReference;
  readbuf := TBufferedStream.Create;
  try
    readbuf.SetPtr(Pointer(S.Memory + S.Position), aSz);
    try
      aDecoder.Decode(readbuf);
      if (FrameHeader.FrameFlag and H2FL_END_HEADERS) > 0 then
      begin
        if aDecoder.Malformed then
           Result := H2E_COMPRESSION_ERROR else
           Result := Strm.FinishHeaders(aDecoder);
      end;
    except
      on e : Exception do
        Result := H2E_COMPRESSION_ERROR;
    end;
  finally
    readbuf.Free;
    aDecoder.DecReference;
  end;
end;

procedure CheckStreamAfterState(Strm : TWCHTTP2Stream);
begin
  if (FrameHeader.FrameFlag and H2FL_END_STREAM) > 0 then
  begin
    if Strm.FStreamState = h2ssOPEN then
    begin
       Strm.FStreamState := h2ssHLFCLOSEDRem;
       Strm.PushRequest;
    end;
  end;
end;

var B : Byte;
    DataSize : Integer;
    RemoteID, CV : Cardinal;
    WV: Word;
    SettFrame : THTTP2SettingsBlock;
    CurStreamClosed, Flag : Boolean;
begin
  Str := nil; RemoteStr := nil;
  if assigned(Mem) then begin
    if (Mem.Size - Mem.Position) = 0 then Exit;
  end else Exit;

  ReadBuffer.Lock;
  try
    FrameHeader := TWCHTTP2FrameHeader.Create;
    S := TBufferedStream.Create;
    try
      Sz := ReadBufferSize - ReadTailSize;
      if Sz <= 0 then
      begin
        err := H2E_READ_BUFFER_OVERFLOW;
        exit;
      end;
      Sz := ReadMore(Mem, ReadTailSize);
      if Sz = ReadTailSize then begin
        err := H2E_INTERNAL_ERROR;
        Exit;
      end;
      S.SetPtr(ReadBuffer.Value, Sz);

      err := H2E_NO_ERROR;
      while true do
      begin
        fallbackpos := S.Position;
        if not LoadMoreData(Mem, S, fallbackpos, H2P_FRAME_HEADER_SIZE, 0) then
        begin
          err := H2E_PARSE_ERROR;
          break;
        end;
        // read header
        FrameHeader.LoadFromStream(S);
        // find stream
        if assigned(Str) then Str.DecReference;
        if assigned(RemoteStr) then RemoteStr.DecReference;
        Str := nil;
        RemoteStr := nil;
        CurStreamClosed := false;

        if FrameHeader.StreamID > 0 then
        begin
          if not TWCHTTP2Helper(Owner.Protocol[wcHTTP2]).CheckStreamID(FrameHeader.StreamID) then
          begin
            err := H2E_PROTOCOL_ERROR;
            break;
          end;
          if FrameHeader.StreamID <= FLastStreamID then
          begin
            Str := FStreams.GetByID(FrameHeader.StreamID);
            if not Assigned(Str) then
            begin
              CurStreamClosed := FStreams.IsStreamInClosedArch(FrameHeader.StreamID);
              if not CurStreamClosed then
              begin
                err := H2E_PROTOCOL_ERROR;
                break;
              end;
            end else
              CurStreamClosed := (Str.StreamState = h2ssCLOSED);
          end else begin
            FLastStreamID := FrameHeader.StreamID;
            if FrameHeader.FrameType in [H2FT_DATA, H2FT_HEADERS,
                                         H2FT_CONTINUATION] then
               FStreams.CloseOldIdleStreams(FLastStreamID);
            if (FStreams.Count >= FConSettings[H2SET_MAX_CONCURRENT_STREAMS]) then
            begin
              err := H2E_REFUSED_STREAM;
              break;
            end;
            Str := AddNewStream(FLastStreamID);
            Str.IncReference;
          end;
          if Assigned(Str) then Str.UpdateState(FrameHeader);
        end else
          Str := nil;

        if Assigned(Str) and
           Str.FWaitingForContinueFrame and
           (FrameHeader.FrameType <> H2FT_CONTINUATION) then
        begin
          err := H2E_PROTOCOL_ERROR;
          break;
        end;
        if (not Assigned(Str)) and
           (not CurStreamClosed) and
           (FrameHeader.FrameType in [H2FT_DATA,
                                      H2FT_CONTINUATION,
                                      H2FT_HEADERS,
                                      H2FT_PRIORITY,
                                      H2FT_RST_STREAM,
                                      H2FT_PUSH_PROMISE]) then
        begin
          err := H2E_PROTOCOL_ERROR; // sec.6.1-6.4,6.6
          break;
        end;
        if (Assigned(Str) or (FrameHeader.StreamID > 0)) and
           (FrameHeader.FrameType in [H2FT_PING,
                                      H2FT_SETTINGS,
                                      H2FT_GOAWAY]) then
        begin
          err := H2E_PROTOCOL_ERROR; // sec.6.5, 6.7
          break;
        end;

        if Http2IsFrameKnown(FrameHeader.FrameType) then
        begin
          if Assigned(Str) and
             (Str.FStreamState = h2ssIDLE) and
             not (FrameHeader.FrameType in [H2FT_HEADERS, H2FT_PRIORITY]) then
          begin
            err := H2E_PROTOCOL_ERROR; // sec.5.1
            break;
          end;
          if ((Assigned(Str) and (Str.FStreamState in [h2ssHLFCLOSEDRem])) or
              CurStreamClosed) and
             not (FrameHeader.FrameType in [H2FT_WINDOW_UPDATE,
                                            H2FT_PRIORITY,
                                            H2FT_RST_STREAM]) then
          begin
            if (FrameHeader.FrameType = H2FT_CONTINUATION) then
            begin
              if not (Assigned(Str) and Str.WaitingForContinueFrame) then
              begin
                err := H2E_PROTOCOL_ERROR; // sec.6.10
                break;
              end;
            end else
            begin
             err := H2E_STREAM_CLOSED; // sec.5.1
             break;
            end;
          end;
        end;

        Sz := FConSettings[H2SET_MAX_FRAME_SIZE];
        case FrameHeader.FrameType of
          H2FT_PING :
            Flag := FrameHeader.PayloadLength <> H2P_PING_SIZE;
          H2FT_WINDOW_UPDATE :
            Flag := FrameHeader.PayloadLength <> H2P_WINDOW_INC_SIZE;
          H2FT_RST_STREAM :
            Flag := FrameHeader.PayloadLength <> H2P_RST_STREAM_FRAME_SIZE;
          H2FT_PRIORITY :
            Flag := FrameHeader.PayloadLength <> H2P_PRIORITY_FRAME_SIZE;
          H2FT_SETTINGS :
            if (FrameHeader.FrameFlag and H2FL_ACK) > 0 then
              Flag := FrameHeader.PayloadLength > 0
            else
              Flag := (FrameHeader.PayloadLength mod H2P_SETTINGS_BLOCK_SIZE) > 0;
          H2FT_GOAWAY :
            Flag := FrameHeader.PayloadLength < H2P_GOAWAY_MIN_SIZE;
        else
          Flag := FrameHeader.PayloadLength > Sz;
        end;
        if Flag then
        begin
          err := H2E_FRAME_SIZE_ERROR;
          break;
        end;

        if not LoadMoreData(Mem, S, fallbackpos,
                                 FrameHeader.PayloadLength,
                                 H2P_FRAME_HEADER_SIZE) then
        begin
          err := H2E_PARSE_ERROR;
          break;
        end;
        if err = H2E_NO_ERROR then
        begin
          // payload fully loaded
          case FrameHeader.FrameType of
            H2FT_DATA : begin
              if not (Str.StreamState in [h2ssOPEN, h2ssHLFCLOSEDLoc]) then
              begin
                err := H2E_STREAM_CLOSED;
                break;
              end;
              DataSize := FrameHeader.PayloadLength;
              if FrameHeader.FrameFlag and H2FL_PADDED > 0 then
              begin
                B := 0;
                S.Read(B, H2P_PADDING_OCTET_SIZE);
                DataSize := DataSize - B;
              end;
              if DataSize < 0 then begin
                err := H2E_PROTOCOL_ERROR;
                break;
              end;
              if not FRecvWindow.Recv(FrameHeader.PayloadLength) then
              begin
                err := H2E_FLOW_CONTROL_ERROR;
                break;
              end;
              if not Str.FRecvWindow.Recv(FrameHeader.PayloadLength) then
              begin
                err := H2E_FLOW_CONTROL_ERROR;
                break;
              end;
              if Str.FRecvWindow.Blocked then
                SendUpdateWindow(Str, HTTP2Settings.GetByID(H2SET_INITIAL_WINDOW_SIZE,
                                                            HTTP2_INITIAL_WINDOW_SIZE));

              if FRecvWindow.Blocked then
                SendUpdateWindow(nil, HTTP2Settings.GetByID(H2SET_INITIAL_WINDOW_SIZE,
                                                            HTTP2_INITIAL_WINDOW_SIZE));

              //
              if not Str.PushData(Pointer(S.Memory + S.Position), DataSize) then
              begin
                err := H2E_INTERNAL_ERROR;
                break;
              end;
              S.Position := S.Position + FrameHeader.PayloadLength;
              CheckStreamAfterState(Str);
            end;
            H2FT_HEADERS : begin
              if not (Str.StreamState in [h2ssIDLE,
                                          h2ssRESERVEDLoc,
                                          h2ssOPEN]) then
              begin
                err := H2E_STREAM_CLOSED;
                break;
              end;
              if Str.FHeadersComplete then
              begin
                err := H2E_PROTOCOL_ERROR;
                break;
              end;
              DataSize := FrameHeader.PayloadLength;
              if FrameHeader.FrameFlag and H2FL_PADDED > 0 then
              begin
                B := 0;
                S.Read(B, H2P_PADDING_OCTET_SIZE);
                DataSize := DataSize - B;
              end;
              if FrameHeader.FrameFlag and H2FL_PRIORITY > 0 then
              begin
                B := 0;
                S.Read(Str.FParentStream, H2P_STREAM_ID_SIZE);
                Str.FParentStream := BETON(Str.FParentStream) and H2P_STREAM_ID_MASK;
                S.Read(Str.FPriority, H2P_PRIORITY_WEIGHT_SIZE);
                DataSize := DataSize - H2P_PRIORITY_FRAME_SIZE;
                if (Str.FParentStream = Str.ID) then
                begin
                  err := H2E_PROTOCOL_ERROR;
                  break;
                end;
                Str.ResetRecursivePriority;
              end;
              err := ProceedHeadersPayload(Str, DataSize);
              if err <> H2E_NO_ERROR then break;
              Str.WaitingForContinueFrame := (FrameHeader.FrameFlag and
                                              H2FL_END_HEADERS) = 0;
              // END_STREAM react here
              CheckStreamAfterState(Str);
            end;
            H2FT_PUSH_PROMISE : begin
              if not (Str.StreamState in [h2ssOPEN,
                                          h2ssHLFCLOSEDLoc]) then
              begin
                err := H2E_STREAM_CLOSED;
                break;
              end;
              DataSize := FrameHeader.PayloadLength;
              if FrameHeader.FrameFlag and H2FL_PADDED > 0 then
              begin
                B := 0;
                S.Read(B, H2P_PADDING_OCTET_SIZE);
                DataSize := DataSize - B;
              end;
              if DataSize < H2P_STREAM_ID_SIZE then begin
                err := H2E_FRAME_SIZE_ERROR;
                break;
              end;
              RemoteID := 0;
              S.Read(RemoteID, H2P_STREAM_ID_SIZE);
              RemoteID := BETON(RemoteID);
              DataSize := DataSize - H2P_STREAM_ID_SIZE;
              if RemoteID = 0 then
              begin
                err := H2E_PROTOCOL_ERROR;
                break;
              end;
              RemoteStr := FStreams.GetByID(RemoteID);
              if assigned(RemoteStr) then
              begin
                if not (RemoteStr.StreamState = h2ssIDLE) then
                begin
                  err := H2E_PROTOCOL_ERROR;
                  break;
                end;
              end else
              if RemoteID <= FLastStreamID then
              begin
                err := H2E_FLOW_CONTROL_ERROR;
                break;
              end else begin
                FLastStreamID := RemoteID;
                RemoteStr := AddNewStream(FLastStreamID);
                RemoteStr.IncReference;
                RemoteStr.FStreamState:=h2ssRESERVEDRem;
              end;
              err := ProceedHeadersPayload(RemoteStr, DataSize);
              if err <> H2E_NO_ERROR then break;
              Str.WaitingForContinueFrame := (FrameHeader.FrameFlag and
                                              H2FL_END_HEADERS = 0);
              RemoteStr.WaitingForContinueFrame := Str.WaitingForContinueFrame;
              Str.FWaitingRemoteStream := RemoteID;
            end;
            H2FT_CONTINUATION : begin
                if not Str.FWaitingForContinueFrame then
                begin
                  err := H2E_PROTOCOL_ERROR;
                  break;
                end;
                if Str.FWaitingRemoteStream <> Str.FID then
                begin
                  RemoteStr := FStreams.GetByID(Str.FWaitingRemoteStream);
                  if not assigned(RemoteStr) then
                  begin
                    err := H2E_STREAM_CLOSED;
                    break;
                  end;
                  if not RemoteStr.FWaitingForContinueFrame then
                  begin
                    err := H2E_INTERNAL_ERROR;
                    break;
                  end;
                  err := ProceedHeadersPayload(RemoteStr, FrameHeader.PayloadLength);
                  if err <> H2E_NO_ERROR then break;
                end else
                begin
                  err := ProceedHeadersPayload(Str, FrameHeader.PayloadLength);
                  if err <> H2E_NO_ERROR then break;
                end;
                Str.WaitingForContinueFrame := (FrameHeader.FrameFlag and
                                                H2FL_END_HEADERS = 0);
                if assigned(RemoteStr) then begin
                  RemoteStr.WaitingForContinueFrame := Str.WaitingForContinueFrame;
                  if not Str.FWaitingForContinueFrame then
                    Str.FWaitingRemoteStream := Str.FID;
                  CheckStreamAfterState(RemoteStr);
                end else
                  CheckStreamAfterState(Str);
              end;
            H2FT_PRIORITY : begin
              S.Read(CV, H2P_STREAM_ID_SIZE);
              if Assigned(Str) then
              begin
                Str.FParentStream := BETON(CV) and H2P_STREAM_ID_MASK;
                if (Str.FParentStream = Str.ID) then
                begin
                  err := H2E_PROTOCOL_ERROR;
                  break;
                end;
              end;
              S.Read(B, H2P_PRIORITY_WEIGHT_SIZE);
              if Assigned(Str) then
              begin
                Str.FPriority := B;
                Str.ResetRecursivePriority;
              end;
            end;
            H2FT_RST_STREAM : begin
              S.Read(CV, H2P_ERROR_CODE_SIZE);
              if Assigned(Str) then
              begin
                Str.FFinishedCode := BETON(CV);
                Str.FStreamState := h2ssCLOSED;
              end;
            end;
            H2FT_SETTINGS : begin
              DataSize := FrameHeader.PayloadLength;

              while DataSize >= H2P_SETTINGS_BLOCK_SIZE do
              begin
                S.Read(SettFrame, H2P_SETTINGS_BLOCK_SIZE);
                WV := SettFrame.Identifier;
                if (WV >= 1) and
                   (WV <= HTTP2_SETTINGS_MAX) then
                begin
                  if FConSettings[WV] <> SettFrame.Value then
                  begin
                    case WV of
                      H2SET_HEADER_TABLE_SIZE,
                      H2SET_MAX_HEADER_LIST_SIZE: ResetHPack;
                      H2SET_INITIAL_WINDOW_SIZE : begin
                        if SettFrame.Value > HTTP2_MAX_WINDOW_UPDATE then
                        begin
                          err := H2E_FLOW_CONTROL_ERROR;
                          break;
                        end;
                        Streams.AdjustWindowSize(Int32(SettFrame.Value) -
                                                  Int32(FConSettings[WV]));
                      end;
                      H2SET_ENABLE_PUSH :
                        if SettFrame.Value > HTTP2_MAX_ENABLE_PUSH then
                        begin
                          err := H2E_PROTOCOL_ERROR;
                          break;
                        end;
                      H2SET_MAX_FRAME_SIZE :
                        if (SettFrame.Value < HTTP2_MIN_MAX_FRAME_SIZE) or
                           (SettFrame.Value > HTTP2_MAX_MAX_FRAME_SIZE) then
                        begin
                          err := H2E_PROTOCOL_ERROR;
                          break;
                        end;
                    end;
                    FConSettings[WV] := SettFrame.Value;
                  end;
                end;
                Dec(DataSize, H2P_SETTINGS_BLOCK_SIZE);
              end;

              // send ack settings frame
              if (FrameHeader.FrameFlag and H2FL_ACK) = 0 then
                PushFrame(H2FT_SETTINGS, Str, H2FL_ACK, nil, 0);
            end;
            H2FT_WINDOW_UPDATE : begin
              S.Read(DataSize, H2P_WINDOW_INC_SIZE);
              DataSize := BETON(DataSize);
              if DataSize = 0 then begin
                err := H2E_PROTOCOL_ERROR;
                break;
              end else
              if (DataSize < 0) then begin
                err := H2E_FLOW_CONTROL_ERROR;
                break;
              end else begin
                if assigned(Str) then begin
                  if (Int32(HTTP2_MAX_WINDOW_UPDATE) - Str.SendWindow.Size) < DataSize then
                  begin
                    err := H2E_FLOW_CONTROL_ERROR;
                    break;
                  end else
                    Str.SendWindow.Update(DataSize);
                end else begin
                  if (Int32(HTTP2_MAX_WINDOW_UPDATE) - FSendWindow.Size) < DataSize then
                  begin
                    err := H2E_FLOW_CONTROL_ERROR;
                    break;
                  end else
                    FSendWindow.Update(DataSize);
                end;
              end;
            end;
            H2FT_GOAWAY : begin
              S.Read(FErrorStream, H2P_STREAM_ID_SIZE);
              FErrorStream := BETON(FErrorStream) and H2P_STREAM_ID_MASK;
              S.Read(FLastError, H2P_ERROR_CODE_SIZE);
              FLastError := BETON(FLastError);
              if FrameHeader.PayloadLength > H2P_GOAWAY_MIN_SIZE then begin
                 FErrorDataSize := FrameHeader.PayloadLength - H2P_GOAWAY_MIN_SIZE;
                 if assigned(FErrorData) then
                    FErrorData := ReallocMem(FErrorData, FErrorDataSize) else
                    FErrorData := GetMem(FErrorDataSize);
                 S.Read(FErrorData^, FErrorDataSize);
              end;
              // drop down connection
              ConnectionState := wcDROPPED;
              break;
            end;
            H2FT_PING : begin
              Buffer := GetMem(H2P_PING_SIZE);
              //fill ping buffer
              S.Read(Buffer^, H2P_PING_SIZE);
              if (FrameHeader.FrameFlag and H2FL_ACK) = 0 then
                PushFrame(H2FT_PING, nil, H2FL_ACK, Buffer, H2P_PING_SIZE) else
                FreeMem(Buffer);
            end;
            else
            begin
              //Implementations MUST ignore and discard any frame that
              //has a type that is unknown. RFC 7540 4.1
            end;
          end;
        end;
        if err in [H2E_NO_ERROR, H2E_FLOW_CONTROL_ERROR] then
          S.Position := fallbackpos + H2P_FRAME_HEADER_SIZE + FrameHeader.PayloadLength;
        if (err <> H2E_NO_ERROR) or (S.Position >= S.Size) then
          break;
      end;

      if S.Position < S.Size then
      begin
        ReadTailSize := S.Size - S.Position;
        TruncReadBuffer(S);
      end else
        ReadTailSize := 0;

    finally
      S.Free;
      if not (err in [H2E_READ_BUFFER_OVERFLOW, H2E_PARSE_ERROR, H2E_NO_ERROR]) then
      begin
        if Assigned(Str) then
        begin
          Str.ResetStream(err);
          Str := nil;
          if not (err in [H2E_FLOW_CONTROL_ERROR]) then
          begin
            GoAway(err);
          end;
        end else
          GoAway(err);
      end;
      if assigned(RemoteStr) then RemoteStr.DecReference;
      if assigned(Str) then Str.DecReference;
      if assigned(FrameHeader) then FrameHeader.Free;
    end;
  finally
    ReadBuffer.UnLock;
  end;
end;

destructor TWCHTTP2Connection.Destroy;
begin
  FStreams.Free;
  ResetHPack;
  FConSettings.Free;
  if assigned(FErrorData) then FreeMem(FErrorData);
  FSendWindow.Free;
  FRecvWindow.Free;
  inherited Destroy;
end;

procedure TWCHTTP2Connection.PushFrame(aFrameType: Byte; aStream: TWCHTTP2Stream;
  aFrameFlags: Byte; aData: Pointer; aDataSize: Cardinal; aOwnPayload: Boolean);
begin
  PushFrame(TWCHTTP2DataFrame.Create(aFrameType, aStream, aFrameFlags, aData,
                                             aDataSize, aOwnPayload));
end;

procedure TWCHTTP2Connection.PushFrame(aFrameType: Byte; aStream: TWCHTTP2Stream;
  aFrameFlags: Byte; aData: TReferencedStream; aStrmPos: Int64;
  aDataSize: Cardinal);
begin
  PushFrame(TWCHTTP2RefFrame.Create(aFrameType, aStream, aFrameFlags, aData,
                                             aStrmPos, aDataSize));
end;

procedure TWCHTTP2Connection.PushFrameFront(aFrameType: Byte;
  aStream: TWCHTTP2Stream; aFrameFlags: Byte; aData: Pointer;
  aDataSize: Cardinal; aOwnPayload: Boolean);
begin
  PushFrameFront(TWCHTTP2DataFrame.Create(aFrameType, aStream, aFrameFlags, aData,
                                             aDataSize, aOwnPayload));
end;

function TWCHTTP2Connection.PopRequestedStream: TWCHTTP2Stream;
begin
  Lock;
  try
    if ConnectionState = wcCONNECTED then
    begin
      Result := FStreams.GetNextStreamWithRequest;
    end else Result := nil;
  finally
    UnLock;
  end;
end;

function TWCHTTP2Connection.PopRequestChunk : TWCHTTP2IncomingChunk;
begin
  Lock;
  try
    if ConnectionState = wcCONNECTED then
    begin
      Result := FStreams.PopNextRequestChunk;
    end else Result := nil;
  finally
    UnLock;
  end;
end;

function TWCHTTP2Connection.TryToIdleStep(const TS : QWord) : Boolean;
begin
  Result:=inherited TryToIdleStep(TS);
  if not ConnectionAvaible then
    FStreams.CloseAll;
  FStreams.RemoveClosedStreams;
end;

procedure TWCHTTP2Connection.ResetStream(aSID, aError: Cardinal);
var S : TWCHTTP2Stream;
begin
  S := FStreams.GetByID(aSID);
  if assigned(S) then
  begin
    S.ResetStream(aError);
  end;
end;

procedure TWCHTTP2Connection.GoAway(aError: Cardinal);
var Buffer : PHTTP2GoawayPayload;
begin
  //send error
  Buffer := GetMem(H2P_GOAWAY_MIN_SIZE);
  //fill goaway buffer
  Buffer^.LastStreamID := FLastStreamID;
  Buffer^.ErrorCode    := aError;
  try
    PushFrame(H2FT_GOAWAY, nil, 0, Buffer, H2P_GOAWAY_MIN_SIZE);
    ConnectionState := wcHALFCLOSED;
  except
    FreeMem(Buffer);
    raise;
  end;
end;

procedure TWCHTTP2Connection.ResetHPack;
begin
  Lock;
  try
    if Assigned(FHPackEncoder) then begin
       FHPackEncoder.DecReference;
       FHPackEncoder := nil;
    end;
    if Assigned(FHPackDecoder) then begin
       FHPackDecoder.DecReference;
       FHPackDecoder := nil;
    end;
  finally
    UnLock;
  end;
end;

procedure TWCHTTP2Connection.InitHPack;
begin
  Lock;
  try
    if not Assigned(FHPackEncoder) then begin
       FHPackEncoder := TThreadSafeHPackEncoder.Create(ConnSettings[H2SET_HEADER_TABLE_SIZE]);
       Owner.GarbageCollector.Add(FHPackEncoder);
    end;
    if not assigned(FHPackDecoder) then begin
       FHPackDecoder :=
         TThreadSafeHPackDecoder.Create(ConnSettings[H2SET_MAX_HEADER_LIST_SIZE],
                              ConnSettings[H2SET_HEADER_TABLE_SIZE]);
       Owner.GarbageCollector.Add(FHPackDecoder);
    end;
  finally
    UnLock;
  end;
end;

function TWCHTTP2Connection.GetInitialReadBufferSize: Cardinal;
begin
  Result := FConSettings[H2SET_INITIAL_WINDOW_SIZE] shl 1;
end;

function TWCHTTP2Connection.GetInitialWriteBufferSize: Cardinal;
begin
  Result := FConSettings[H2SET_INITIAL_WINDOW_SIZE];
end;

function TWCHTTP2Connection.CanExpandWriteBuffer({%H-}aCurSize,
  {%H-}aNeedSize: Cardinal): Boolean;
begin
  Result := false;
end;

function TWCHTTP2Connection.RequestsWaiting: Boolean;
begin
  Result :=  FStreams.HasStreamWithRequest;
end;

function TWCHTTP2Connection.NextFrameToSend(it : TIteratorObject): TIteratorObject;
var AvaibleSendWindow : Int32;

function CanSend(fr : TWCHTTP2Frame) : Boolean;
var nfr : TWCHTTP2RefFrame;
begin
  if fr.Header.FrameType in HTTP2_FLOW_CONTROL_FRAME_TYPES then
  begin
    if fr.Stream.FSendWindow.Blocked then Exit(false);
    AvaibleSendWindow := fr.Stream.FSendWindow.Size;
    if FSendWindow.Size < AvaibleSendWindow then
      AvaibleSendWindow := FSendWindow.Size;
    Result := (AvaibleSendWindow >= fr.Header.PayloadLength);
    if (not Result) and (fr is TWCHTTP2RefFrame) and
       (AvaibleSendWindow > 0) then
    begin
      nfr := TWCHTTP2RefFrame.Create(fr.Header.FrameType,
                                     fr.Stream,
                                     fr.Header.FrameFlag and (not H2FL_END_STREAM),
                                     TWCHTTP2RefFrame(fr).FStrm,
                                     TWCHTTP2RefFrame(fr).Fpos,
                                     AvaibleSendWindow);
      Inc(TWCHTTP2RefFrame(fr).Fpos, AvaibleSendWindow);
      Dec(fr.Header.PayloadLength, AvaibleSendWindow);
      it := FramesToSend.InsertBefore(it, nfr);
      Result := true;
    end;
    if not Result then
      fr.Stream.FSendWindow.Block;
  end else Result := true;
end;

var Str : TWCHTTP2Stream;
begin
  while Assigned(it) do
  begin
    if not CanSend(TWCHTTP2Frame(it.Value)) then
    begin
      Str := TWCHTTP2Frame(it.Value).Stream;
      repeat
        it := it.Next;
        if Assigned(it) and (TWCHTTP2Frame(it.Value).Stream <> Str) then
        begin
          break;
        end;
      until not Assigned(it);
    end else
      Break;
  end;
  Result := it;
end;

procedure TWCHTTP2Connection.AfterFrameSent(fr: TWCRefProtoFrame);
begin
  if fr is TWCHTTP2Frame then
  begin
    if (TWCHTTP2Frame(fr).Header.FrameType in [H2FT_HEADERS,
                                               H2FT_DATA]) and
       ((TWCHTTP2Frame(fr).Header.FrameFlag and H2FL_END_STREAM) > 0) then
       TWCHTTP2Frame(fr).Stream.FStreamState := h2ssCLOSED;
    if TWCHTTP2Frame(fr).Header.FrameType in HTTP2_FLOW_CONTROL_FRAME_TYPES then
    begin
      if Assigned(TWCHTTP2Frame(fr).Stream) then
        TWCHTTP2Frame(fr).Stream.FSendWindow.Send(TWCHTTP2Frame(fr).Header.PayloadLength);
      FSendWindow.Send(TWCHTTP2Frame(fr).Header.PayloadLength);
    end else
    if TWCHTTP2Frame(fr).Header.FrameType = H2FT_WINDOW_UPDATE then
    begin
      if Assigned(TWCHTTP2Frame(fr).Stream) then
        TWCHTTP2Frame(fr).Stream.FRecvWindow.Update(PHTTP2WindowUpdatePayload(TWCHTTP2Frame(fr).Memory)^.WindowSize)
      else
        FRecvWindow.Update(PHTTP2WindowUpdatePayload(TWCHTTP2Frame(fr).Memory)^.WindowSize);
    end;
  end;
end;

procedure TWCHTTP2Connection.SendUpdateWindow(aStrm : TWCHTTP2Stream;
  aWinSize : Int32);
var pv : PHTTP2WindowUpdatePayload;
begin
  pv := GetMem(H2P_WINDOW_INC_SIZE);
  pv^.WindowSize := aWinSize;
  PushFrame(H2FT_WINDOW_UPDATE, aStrm, 0, pv, H2P_WINDOW_INC_SIZE);
end;

{ TWCHTTP2Streams }

procedure TWCHTTP2Streams.AddClosedStream(SID: Cardinal);
var it, nit : TIteratorObject;
begin
  FClosedStreams.Lock;
  try
    nit := nil;
    it := FClosedStreams.ListBegin;
    while Assigned(it) do
    begin
      if TWCHTTP2ClosedStreams(it.Value).Contain(SID) then
      begin
        Break;
      end;
      if TWCHTTP2ClosedStreams(it.Value).Expand(SID) then
      begin
        nit := it;
        Break;
      end;
      if TWCHTTP2ClosedStreams(it.Value).StartFrom > SID then
      begin
        nit := FClosedStreams.InsertBefore(it, TWCHTTP2ClosedStreams.Create(SID));
        break;
      end;
      it := it.Next;
    end;
    if Assigned(nit) then
    begin
      //one-direction merging pass
      it := FClosedStreams.ListBegin;
      while Assigned(it) do
      begin
        nit := it.Next;
        if Assigned(nit) then
        begin
          if TWCHTTP2ClosedStreams(it.Value).MergeRight(TWCHTTP2ClosedStreams(nit.Value)) then
          begin
            FClosedStreams.Erase(nit);
          end else
            it := nit;
        end else
          it := nil;
      end;
    end else
      FClosedStreams.Push_back(TWCHTTP2ClosedStreams.Create(SID));
  finally
    FClosedStreams.UnLock;
  end;
end;

function TWCHTTP2Streams.IsStreamClosed(aStrm: TObject; {%H-}data: pointer): Boolean;
begin
  Result := (TWCHTTP2Stream(aStrm).StreamState = h2ssCLOSED);
end;

procedure TWCHTTP2Streams.AfterStrmExtracted(aObj: TObject);
begin
  AddClosedStream(TWCHTTP2Stream(aObj).ID);
  TWCHTTP2Stream(aObj).DecReference;
end;

procedure TWCHTTP2Streams.DoCloseStream(aObj : TObject);
begin
  TWCHTTP2Stream(aObj).Lock;
  try
    TWCHTTP2Stream(aObj).FStreamState := h2ssCLOSED;
  finally
    TWCHTTP2Stream(aObj).UnLock;
  end;
end;

constructor TWCHTTP2Streams.Create;
begin
  inherited Create;
  FClosedStreams := TThreadSafeFastSeq.Create;
end;

destructor TWCHTTP2Streams.Destroy;
var P :TIteratorObject;
begin
  Lock;
  try
    P := ListBegin;
    while assigned(P) do
    begin
      TWCHTTP2Stream(P.Value).DecReference;
      P := P.Next;
    end;
    ExtractAll;
  finally
    UnLock;
  end;
  FClosedStreams.Free;
  inherited Destroy;
end;

function TWCHTTP2Streams.IsStreamInClosedArch(SID: Cardinal): Boolean;
var it : TIteratorObject;
begin
  Result := false;
  FClosedStreams.Lock;
  try
    it := FClosedStreams.ListBegin;
    while Assigned(it) do
    begin
      if TWCHTTP2ClosedStreams(it.Value).Contain(SID) then
        Exit(True);

      it := it.Next;
    end;
  finally
    FClosedStreams.UnLock;
  end;
end;

function TWCHTTP2Streams.GetByID(aID: Cardinal): TWCHTTP2Stream;
var P : TIteratorObject;
begin
  Lock;
  try
    P := ListBegin;
    while assigned(P) do
    begin
      if TWCHTTP2Stream(P.Value).ID = aID then
      begin
        Result := TWCHTTP2Stream(P.Value);
        Result.IncReference;
        Exit;
      end;
      P := P.Next;
    end;
  finally
    UnLock;
  end;
  Result := nil;
end;

function TWCHTTP2Streams.GetNextStreamWithRequest: TWCHTTP2Stream;
var P : TIteratorObject;
begin
  Lock;
  try
    P := ListBegin;
    while assigned(P) do
    begin
      if TWCHTTP2Stream(P.Value).RequestReady then
      begin
        Result := TWCHTTP2Stream(P.Value);
        Result.ResponseProceed := true;
        Result.IncReference;
        Exit;
      end;
      P := P.Next;
    end;
  finally
    UnLock;
  end;
  Result := nil;
end;

function TWCHTTP2Streams.PopNextRequestChunk : TWCHTTP2IncomingChunk;
var P : TIteratorObject;
begin
  Lock;
  try
    P := ListBegin;
    while assigned(P) do
    begin
      Result := TWCHTTP2Stream(P.Value).PopRequestChunk;
      if Assigned(Result) then
        Exit;

      P := P.Next;
    end;
  finally
    UnLock;
  end;
  Result := nil;
end;

function TWCHTTP2Streams.HasStreamWithRequest: Boolean;
var P : TIteratorObject;
begin
  Lock;
  try
    P := ListBegin;
    while assigned(P) do
    begin
      if TWCHTTP2Stream(P.Value).RequestReady or
         TWCHTTP2Stream(P.Value).ChunkReady then
      begin
        Result := true;
        Exit;
      end;
      P := P.Next;
    end;
  finally
    UnLock;
  end;
  Result := false;
end;

procedure TWCHTTP2Streams.CloseOldIdleStreams(aMaxId: Cardinal);
var NP, P : TIteratorObject;
begin
  // close all idle stream with id less than aMaxId
  // sec.5.1.1 IRF7540
  Lock;
  try
    P := ListBegin;
    while assigned(P) do
    begin
      NP := P.Next;
      if (TWCHTTP2Stream(P.Value).ID < aMaxId) and
         (TWCHTTP2Stream(P.Value).StreamState = h2ssIDLE) then
      begin
        TWCHTTP2Stream(P.Value).DecReference;
        Extract(P);
      end;
      P := NP;
    end;
  finally
    UnLock;
  end;
end;

procedure TWCHTTP2Streams.AdjustWindowSize(Delta: Int32);
var P : TIteratorObject;
begin
  Lock;
  try
    P := ListBegin;
    while assigned(P) do
    begin
      TWCHTTP2Stream(P.Value).FSendWindow.Update(Delta);
      P := P.Next;
    end;
  finally
    UnLock;
  end;
end;

procedure TWCHTTP2Streams.RemoveClosedStreams;
begin
  ExtractObjectsByCriteria(@IsStreamClosed, @AfterStrmExtracted, nil);
end;

procedure TWCHTTP2Streams.CloseAll;
begin
  DoForAll(@DoCloseStream);
end;

{ TWCHTTP2Stream }

function TWCHTTP2Stream.GetRecursedPriority: Byte;
begin
  if FRecursedPriority < 0 then begin
    Result := FPriority; // todo: calc priority here
    FRecursedPriority:= Result;
  end else Result := FRecursedPriority;
end;

function TWCHTTP2Stream.GetRequestProceed : TWCHTTP2IncomingChunksMode;
begin
  Lock;
  try
    Result := FIncomingChunksMode;
  finally
    UnLock;
  end;
end;

function TWCHTTP2Stream.GetCurResponse : TWCHTTP2Response;
begin
  Result := FCurRequest.Response;
end;

function TWCHTTP2Stream.GetExtData : TObject;
begin
  Result := FExternalData;
end;

function TWCHTTP2Stream.GetResponseProceed: Boolean;
begin
  Lock;
  try
    Result := FResponseProceed;
  finally
    UnLock;
  end;
end;

procedure TWCHTTP2Stream.ResetRecursivePriority;
begin
  FRecursedPriority := -1;
end;

procedure TWCHTTP2Stream.PushRequest;
begin
  FCurRequest.Complete := true;
end;

procedure TWCHTTP2Stream.SetExtData(AValue : TObject);
begin
  FExternalData := AValue;
end;

procedure TWCHTTP2Stream.SetRequestProceed(AValue : TWCHTTP2IncomingChunksMode);
begin
  Lock;
  try
    if FIncomingChunksMode=AValue then Exit;
    if AValue > h2icmNone then
      FIncomingChunks := TWCHTTP2IncomingChunks.Create else
      FreeAndNil(FIncomingChunks);
    FIncomingChunksMode := AValue;
  finally
    UnLock;
  end;
end;

procedure TWCHTTP2Stream.SetResponseProceed(AValue: Boolean);
begin
  Lock;
  try
    if FResponseProceed=AValue then Exit;
    FResponseProceed:=AValue;
  finally
    UnLock;
  end;
end;

procedure TWCHTTP2Stream.SetWaitingForContinueFrame(AValue: Boolean);
begin
  if FWaitingForContinueFrame=AValue then Exit;
  FWaitingForContinueFrame:=AValue;
  FHeadersComplete:=not AValue;
end;

procedure TWCHTTP2Stream.UpdateState(Head: TWCHTTP2FrameHeader);
begin
  case FStreamState of
    h2ssIDLE : begin
     if Head.FrameType = H2FT_HEADERS then
        FStreamState := h2ssOPEN;
     end;
    h2ssRESERVEDRem : begin
     if Head.FrameType = H2FT_HEADERS then
        FStreamState := h2ssHLFCLOSEDLoc;
    end;
  end;
end;

procedure TWCHTTP2Stream.DoCopyToHTTP1Request(AReq : TWCConnectionRequest);
var
  i, j : integer;
  h : PHTTPHeader;
  v : PHPackHeaderTextItem;
  S : String;
begin
  with FCurRequest do
  try
    for i := 0 to FHeaders.Count-1 do
    begin
      v := FHeaders[i];
      h := GetHTTPHeaderType(v^.HeaderName);
      if assigned(h) then
      begin
        if h^.h2 <> hh2Unknown then
        begin
          case h^.h2 of
            hh2Method : AReq.Method := v^.HeaderValue;
            hh2Path   : begin
              AReq.URL:= v^.HeaderValue;
              S:=AReq.URL;
              j:=Pos('?',S);
              if (j>0) then
                S:=Copy(S,1,j-1);
              If (Length(S)>1) and (S[1]<>'/') then
                S:='/'+S
              else if S='/' then
                S:='';
              AReq.PathInfo:=S;
            end;
            hh2Authority, hh2Scheme, hh2Status : ;
            hh2Cookie : begin
              AReq.CookieFields.Add(v^.HeaderValue);
            end
          else
            AReq.SetCustomHeader(HTTP2AddHeaderNames[h^.h2], v^.HeaderValue);
          end;
        end else
        if h^.h1 <> hhUnknown then
        begin
          AReq.SetHeader(h^.h1, v^.HeaderValue);
        end else
          AReq.SetCustomHeader(v^.HeaderName, v^.HeaderValue);
      end else
          AReq.SetCustomHeader(v^.HeaderName, v^.HeaderValue);
    end;
    AReq.WCContent.RequestRef := Self;
  finally
    //
  end;
end;

function TWCHTTP2Stream.PushData(Data : Pointer; sz : Cardinal) : Boolean;
begin
  if ChunkedRequest > h2icmNone then
  begin
    Result := PushChunk(Data, sz);
  end else
  begin
    Lock;
    try
      FCurRequest.PushData(Data, sz);
      Result := true;
    finally
      UnLock;
    end;
  end;
end;

function TWCHTTP2Stream.PushChunk(Data : Pointer; sz : Cardinal) : Boolean;
var Chunk : TWCHTTP2IncomingChunk;
begin
  Chunk := FIncomingChunks.PushChunk(Self, Data, sz);
  if Assigned(Chunk) then
  begin
    Chunk.IncReference;
    FConnection.Owner.GarbageCollector.Add(Chunk);
    Result := true;
  end else
    Result := false;
end;

function TWCHTTP2Stream.FinishHeaders(aDecoder: TThreadSafeHPackDecoder) : Byte;
var i : integer;
    p : PHPackHeaderTextItem;
    PseudoHeaders : Boolean;
    h2 : THTTP2Header;
    PHValues : THTTP2PseudoHeaders = ('', '', '', '', '');
begin
  Result := H2E_NO_ERROR;
  FHeadersComplete := true;
  //check headers
  //according RFC 7540 8.1. HTTP Request/Response Exchange
  //sec.8.1.2
  aDecoder.IncReference;
  aDecoder.Lock;
  try
    PseudoHeaders := true;
    for i := 0 to aDecoder.DecodedHeaders.Count-1 do
    begin
      P := aDecoder.DecodedHeaders[i];
      if not SameStr(LowerCase(P^.HeaderName), P^.HeaderName) then
      begin
        Result := H2E_PROTOCOL_ERROR;
        Exit;
      end;
      h2 := HTTP2HeaderType(P^.HeaderName);
      if HTTP2HeaderIsPseudo(h2) then
      begin
        if PseudoHeaders then begin
          if h2 in [hh2Method..hh2Status] then
          begin
            if Length(PHValues[h2]) > 0 then
            begin
              Result := H2E_PROTOCOL_ERROR;
              Exit;
            end else
            begin
              PHValues[h2] := P^.HeaderValue;
            end;
          end;
        end else
        begin
          Result := H2E_PROTOCOL_ERROR;
          Exit
        end;
      end else
      begin
        if P^.HeaderName[1] = ':' then
        begin
          Result := H2E_PROTOCOL_ERROR;
          Exit;
        end;
        if SameStr(p^.HeaderName, 'te') and
           (not SameStr(p^.HeaderValue, 'trailers')) then
        begin
          Result := H2E_PROTOCOL_ERROR;
          Exit;
        end;
        if PseudoHeaders then PseudoHeaders := false;
      end;
    end;

    //specific checks
    Result := TWCHTTP2Helper(FConnection.Owner.Protocol[wcHTTP2]).CheckHeaders(aDecoder, PHValues);
  finally
    aDecoder.UnLock;
    aDecoder.DecReference;
  end;
  if Result = H2E_NO_ERROR then begin
    FCurRequest.CopyHeaders(aDecoder);
    //specific reactions
    TWCHTTP2Helper(FConnection.Owner.Protocol[wcHTTP2]).ConfigureStream(Self);
  end;
end;

function TWCHTTP2Stream.ChunksReleased : Boolean;
begin
  if Assigned(FIncomingChunks) then
    Result := FIncomingChunks.IsReleased else
    Result := true;
end;

constructor TWCHTTP2Stream.Create(aConnection: TWCHTTP2Connection;
  aStreamID: Cardinal);
begin
  inherited Create;
  FID := aStreamID;
  FConnection := aConnection;
  FStreamState:= h2ssIDLE;
  FRecursedPriority:=-1;
  FFinishedCode := H2E_NO_ERROR;
  FWaitingForContinueFrame := false;
  FWaitingRemoteStream := aStreamID;
  FHeadersComplete := false;
  FSendWindow := TThreadSafeHTTP2WindowSize.Create(aConnection.ConnSettings[H2SET_INITIAL_WINDOW_SIZE]);
  FRecvWindow := TThreadSafeHTTP2WindowSize.Create(aConnection.HTTP2Settings.GetByID(H2SET_INITIAL_WINDOW_SIZE,
                                                                         HTTP2_INITIAL_WINDOW_SIZE));
  FCurRequest := TWCHTTP2Request.Create(FConnection, Self);
  FResponseProceed := false;
  FIncomingChunks := nil;
  FIncomingChunksMode := h2icmNone;
  FExternalData := nil;
  FOwnExtData := true;
end;

destructor TWCHTTP2Stream.Destroy;
begin
  if assigned(FCurRequest) then FreeAndNil(FCurRequest);
  FSendWindow.Free;
  FRecvWindow.Free;
  if assigned(FIncomingChunks) then FreeAndNil(FIncomingChunks);
  if assigned(FExternalData) and FOwnExtData then FreeAndNil(FExternalData);
  inherited Destroy;
end;

procedure TWCHTTP2Stream.Release;
var er : PHTTP2RstStreamPayload;
begin
  if (FStreamState <> h2ssCLOSED) then
  begin
    if (FFinishedCode <> H2E_NO_ERROR) then
    begin
      er := GetMem(H2P_RST_STREAM_FRAME_SIZE);
      er^.ErrorCode := FFinishedCode;
      FConnection.PushFrame(H2FT_RST_STREAM, Self, 0, er, H2P_RST_STREAM_FRAME_SIZE);
      FStreamState := h2ssCLOSED;
    end else
    begin
      if not FCurRequest.ResponsePushed then // some error occured -
                              // stream released but no response frames pushed
                              // stream is zombie and need to be closed
      begin
        FStreamState := h2ssCLOSED;
      end;
    end;
  end;
  inherited Release;
end;

procedure TWCHTTP2Stream.ResetStream(aError : Cardinal);
begin
  FFinishedCode := aError;
  Release;
end;

function TWCHTTP2Stream.GetReqContentStream: TStream;
begin
  if assigned(FCurRequest) then
  begin
    if FCurRequest.DataBlockSize > 0 then
    begin
     Result := FCurRequest.Data;
    end else
     Result := nil;
  end else
     Result := nil;
end;

function TWCHTTP2Stream.IsReqContentStreamOwn: Boolean;
begin
  Result := true;
end;

procedure TWCHTTP2Stream.HoldChunks;
begin
  if (FIncomingChunksMode = h2icmSerial) then
    FIncomingChunks.Hold;
end;

procedure TWCHTTP2Stream.ReleaseChunks;
begin
  if (FIncomingChunksMode = h2icmSerial) then
    FIncomingChunks.Release;
end;

procedure TWCHTTP2Stream.CopyToHTTP1Request(AReq: TWCConnectionRequest);
begin
  with FCurRequest do
  if Complete then
  begin
    DoCopyToHTTP1Request(Areq);
  end;
end;

function TWCHTTP2Stream.RequestReady: Boolean;
begin
  Lock;
  try
    Result := FCurRequest.Complete and
              FHeadersComplete and
              (not FResponseProceed);
  finally
    UnLock;
  end;
end;

function TWCHTTP2Stream.ChunkReady : Boolean;
begin
  if Assigned(FIncomingChunks) then
    Result := (FIncomingChunks.Count > 0) else
    Result := false;
end;

function TWCHTTP2Stream.PopRequestChunk : TWCHTTP2IncomingChunk;
begin
  if Assigned(FIncomingChunks) and ChunksReleased then
  begin
    Result := FIncomingChunks.PopChunk;
  end else
    Result := nil;
end;

end.
