//
//  Generated code. Do not modify.
//  source: extension/extension_service.proto
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

import '../v2/hcommon/common.pb.dart' as $2;
import 'extension.pb.dart' as $7;

export 'extension_service.pb.dart';

@$pb.GrpcServiceName('extension.ExtensionHostService')
class ExtensionHostServiceClient extends $grpc.Client {
  static final _$listExtensions = $grpc.ClientMethod<$2.Empty, $7.ExtensionList>(
      '/extension.ExtensionHostService/ListExtensions',
      ($2.Empty value) => value.writeToBuffer(),
      ($core.List<$core.int> value) => $7.ExtensionList.fromBuffer(value));
  static final _$connect = $grpc.ClientMethod<$7.ExtensionRequest, $7.ExtensionResponse>(
      '/extension.ExtensionHostService/Connect',
      ($7.ExtensionRequest value) => value.writeToBuffer(),
      ($core.List<$core.int> value) => $7.ExtensionResponse.fromBuffer(value));
  static final _$editExtension = $grpc.ClientMethod<$7.EditExtensionRequest, $7.ExtensionActionResult>(
      '/extension.ExtensionHostService/EditExtension',
      ($7.EditExtensionRequest value) => value.writeToBuffer(),
      ($core.List<$core.int> value) => $7.ExtensionActionResult.fromBuffer(value));
  static final _$submitForm = $grpc.ClientMethod<$7.SendExtensionDataRequest, $7.ExtensionActionResult>(
      '/extension.ExtensionHostService/SubmitForm',
      ($7.SendExtensionDataRequest value) => value.writeToBuffer(),
      ($core.List<$core.int> value) => $7.ExtensionActionResult.fromBuffer(value));
  static final _$close = $grpc.ClientMethod<$7.ExtensionRequest, $7.ExtensionActionResult>(
      '/extension.ExtensionHostService/Close',
      ($7.ExtensionRequest value) => value.writeToBuffer(),
      ($core.List<$core.int> value) => $7.ExtensionActionResult.fromBuffer(value));
  static final _$getUI = $grpc.ClientMethod<$7.ExtensionRequest, $7.ExtensionActionResult>(
      '/extension.ExtensionHostService/GetUI',
      ($7.ExtensionRequest value) => value.writeToBuffer(),
      ($core.List<$core.int> value) => $7.ExtensionActionResult.fromBuffer(value));

  ExtensionHostServiceClient($grpc.ClientChannel channel,
      {$grpc.CallOptions? options,
      $core.Iterable<$grpc.ClientInterceptor>? interceptors})
      : super(channel, options: options,
        interceptors: interceptors);

  $grpc.ResponseFuture<$7.ExtensionList> listExtensions($2.Empty request, {$grpc.CallOptions? options}) {
    return $createUnaryCall(_$listExtensions, request, options: options);
  }

  $grpc.ResponseStream<$7.ExtensionResponse> connect($7.ExtensionRequest request, {$grpc.CallOptions? options}) {
    return $createStreamingCall(_$connect, $async.Stream.fromIterable([request]), options: options);
  }

  $grpc.ResponseFuture<$7.ExtensionActionResult> editExtension($7.EditExtensionRequest request, {$grpc.CallOptions? options}) {
    return $createUnaryCall(_$editExtension, request, options: options);
  }

  $grpc.ResponseFuture<$7.ExtensionActionResult> submitForm($7.SendExtensionDataRequest request, {$grpc.CallOptions? options}) {
    return $createUnaryCall(_$submitForm, request, options: options);
  }

  $grpc.ResponseFuture<$7.ExtensionActionResult> close($7.ExtensionRequest request, {$grpc.CallOptions? options}) {
    return $createUnaryCall(_$close, request, options: options);
  }

  $grpc.ResponseFuture<$7.ExtensionActionResult> getUI($7.ExtensionRequest request, {$grpc.CallOptions? options}) {
    return $createUnaryCall(_$getUI, request, options: options);
  }
}

@$pb.GrpcServiceName('extension.ExtensionHostService')
abstract class ExtensionHostServiceBase extends $grpc.Service {
  $core.String get $name => 'extension.ExtensionHostService';

  ExtensionHostServiceBase() {
    $addMethod($grpc.ServiceMethod<$2.Empty, $7.ExtensionList>(
        'ListExtensions',
        listExtensions_Pre,
        false,
        false,
        ($core.List<$core.int> value) => $2.Empty.fromBuffer(value),
        ($7.ExtensionList value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$7.ExtensionRequest, $7.ExtensionResponse>(
        'Connect',
        connect_Pre,
        false,
        true,
        ($core.List<$core.int> value) => $7.ExtensionRequest.fromBuffer(value),
        ($7.ExtensionResponse value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$7.EditExtensionRequest, $7.ExtensionActionResult>(
        'EditExtension',
        editExtension_Pre,
        false,
        false,
        ($core.List<$core.int> value) => $7.EditExtensionRequest.fromBuffer(value),
        ($7.ExtensionActionResult value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$7.SendExtensionDataRequest, $7.ExtensionActionResult>(
        'SubmitForm',
        submitForm_Pre,
        false,
        false,
        ($core.List<$core.int> value) => $7.SendExtensionDataRequest.fromBuffer(value),
        ($7.ExtensionActionResult value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$7.ExtensionRequest, $7.ExtensionActionResult>(
        'Close',
        close_Pre,
        false,
        false,
        ($core.List<$core.int> value) => $7.ExtensionRequest.fromBuffer(value),
        ($7.ExtensionActionResult value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$7.ExtensionRequest, $7.ExtensionActionResult>(
        'GetUI',
        getUI_Pre,
        false,
        false,
        ($core.List<$core.int> value) => $7.ExtensionRequest.fromBuffer(value),
        ($7.ExtensionActionResult value) => value.writeToBuffer()));
  }

  $async.Future<$7.ExtensionList> listExtensions_Pre($grpc.ServiceCall call, $async.Future<$2.Empty> request) async {
    return listExtensions(call, await request);
  }

  $async.Stream<$7.ExtensionResponse> connect_Pre($grpc.ServiceCall call, $async.Future<$7.ExtensionRequest> request) async* {
    yield* connect(call, await request);
  }

  $async.Future<$7.ExtensionActionResult> editExtension_Pre($grpc.ServiceCall call, $async.Future<$7.EditExtensionRequest> request) async {
    return editExtension(call, await request);
  }

  $async.Future<$7.ExtensionActionResult> submitForm_Pre($grpc.ServiceCall call, $async.Future<$7.SendExtensionDataRequest> request) async {
    return submitForm(call, await request);
  }

  $async.Future<$7.ExtensionActionResult> close_Pre($grpc.ServiceCall call, $async.Future<$7.ExtensionRequest> request) async {
    return close(call, await request);
  }

  $async.Future<$7.ExtensionActionResult> getUI_Pre($grpc.ServiceCall call, $async.Future<$7.ExtensionRequest> request) async {
    return getUI(call, await request);
  }

  $async.Future<$7.ExtensionList> listExtensions($grpc.ServiceCall call, $2.Empty request);
  $async.Stream<$7.ExtensionResponse> connect($grpc.ServiceCall call, $7.ExtensionRequest request);
  $async.Future<$7.ExtensionActionResult> editExtension($grpc.ServiceCall call, $7.EditExtensionRequest request);
  $async.Future<$7.ExtensionActionResult> submitForm($grpc.ServiceCall call, $7.SendExtensionDataRequest request);
  $async.Future<$7.ExtensionActionResult> close($grpc.ServiceCall call, $7.ExtensionRequest request);
  $async.Future<$7.ExtensionActionResult> getUI($grpc.ServiceCall call, $7.ExtensionRequest request);
}
