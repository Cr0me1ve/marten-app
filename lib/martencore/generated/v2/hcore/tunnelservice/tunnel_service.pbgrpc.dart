//
//  Generated code. Do not modify.
//  source: v2/hcore/tunnelservice/tunnel_service.proto
//
// @dart = 2.12

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_final_fields
// ignore_for_file: unnecessary_import, unnecessary_this, unused_import

import 'dart:async' as $async;
import 'dart:core' as $core;

import 'package:grpc/service_api.dart' as $grpc;
import 'package:protobuf/protobuf.dart' as $pb;

import '../../hcommon/common.pb.dart' as $2;
import 'tunnel.pb.dart' as $3;

export 'tunnel_service.pb.dart';

@$pb.GrpcServiceName('tunnelservice.TunnelService')
class TunnelServiceClient extends $grpc.Client {
  static final _$start = $grpc.ClientMethod<$3.TunnelStartRequest, $3.TunnelResponse>(
      '/tunnelservice.TunnelService/Start',
      ($3.TunnelStartRequest value) => value.writeToBuffer(),
      ($core.List<$core.int> value) => $3.TunnelResponse.fromBuffer(value));
  static final _$stop = $grpc.ClientMethod<$2.Empty, $3.TunnelResponse>(
      '/tunnelservice.TunnelService/Stop',
      ($2.Empty value) => value.writeToBuffer(),
      ($core.List<$core.int> value) => $3.TunnelResponse.fromBuffer(value));
  static final _$status = $grpc.ClientMethod<$2.Empty, $3.TunnelResponse>(
      '/tunnelservice.TunnelService/Status',
      ($2.Empty value) => value.writeToBuffer(),
      ($core.List<$core.int> value) => $3.TunnelResponse.fromBuffer(value));
  static final _$exit = $grpc.ClientMethod<$2.Empty, $3.TunnelResponse>(
      '/tunnelservice.TunnelService/Exit',
      ($2.Empty value) => value.writeToBuffer(),
      ($core.List<$core.int> value) => $3.TunnelResponse.fromBuffer(value));

  TunnelServiceClient($grpc.ClientChannel channel,
      {$grpc.CallOptions? options,
      $core.Iterable<$grpc.ClientInterceptor>? interceptors})
      : super(channel, options: options,
        interceptors: interceptors);

  $grpc.ResponseFuture<$3.TunnelResponse> start($3.TunnelStartRequest request, {$grpc.CallOptions? options}) {
    return $createUnaryCall(_$start, request, options: options);
  }

  $grpc.ResponseFuture<$3.TunnelResponse> stop($2.Empty request, {$grpc.CallOptions? options}) {
    return $createUnaryCall(_$stop, request, options: options);
  }

  $grpc.ResponseFuture<$3.TunnelResponse> status($2.Empty request, {$grpc.CallOptions? options}) {
    return $createUnaryCall(_$status, request, options: options);
  }

  $grpc.ResponseFuture<$3.TunnelResponse> exit($2.Empty request, {$grpc.CallOptions? options}) {
    return $createUnaryCall(_$exit, request, options: options);
  }
}

@$pb.GrpcServiceName('tunnelservice.TunnelService')
abstract class TunnelServiceBase extends $grpc.Service {
  $core.String get $name => 'tunnelservice.TunnelService';

  TunnelServiceBase() {
    $addMethod($grpc.ServiceMethod<$3.TunnelStartRequest, $3.TunnelResponse>(
        'Start',
        start_Pre,
        false,
        false,
        ($core.List<$core.int> value) => $3.TunnelStartRequest.fromBuffer(value),
        ($3.TunnelResponse value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$2.Empty, $3.TunnelResponse>(
        'Stop',
        stop_Pre,
        false,
        false,
        ($core.List<$core.int> value) => $2.Empty.fromBuffer(value),
        ($3.TunnelResponse value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$2.Empty, $3.TunnelResponse>(
        'Status',
        status_Pre,
        false,
        false,
        ($core.List<$core.int> value) => $2.Empty.fromBuffer(value),
        ($3.TunnelResponse value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$2.Empty, $3.TunnelResponse>(
        'Exit',
        exit_Pre,
        false,
        false,
        ($core.List<$core.int> value) => $2.Empty.fromBuffer(value),
        ($3.TunnelResponse value) => value.writeToBuffer()));
  }

  $async.Future<$3.TunnelResponse> start_Pre($grpc.ServiceCall call, $async.Future<$3.TunnelStartRequest> request) async {
    return start(call, await request);
  }

  $async.Future<$3.TunnelResponse> stop_Pre($grpc.ServiceCall call, $async.Future<$2.Empty> request) async {
    return stop(call, await request);
  }

  $async.Future<$3.TunnelResponse> status_Pre($grpc.ServiceCall call, $async.Future<$2.Empty> request) async {
    return status(call, await request);
  }

  $async.Future<$3.TunnelResponse> exit_Pre($grpc.ServiceCall call, $async.Future<$2.Empty> request) async {
    return exit(call, await request);
  }

  $async.Future<$3.TunnelResponse> start($grpc.ServiceCall call, $3.TunnelStartRequest request);
  $async.Future<$3.TunnelResponse> stop($grpc.ServiceCall call, $2.Empty request);
  $async.Future<$3.TunnelResponse> status($grpc.ServiceCall call, $2.Empty request);
  $async.Future<$3.TunnelResponse> exit($grpc.ServiceCall call, $2.Empty request);
}
