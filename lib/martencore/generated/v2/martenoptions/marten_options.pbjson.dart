//
//  Generated code. Do not modify.
//  source: v2/martenoptions/marten_options.proto
//
// @dart = 2.12

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_final_fields
// ignore_for_file: unnecessary_import, unnecessary_this, unused_import

import 'dart:convert' as $convert;
import 'dart:core' as $core;
import 'dart:typed_data' as $typed_data;

@$core.Deprecated('Use domainStrategyDescriptor instead')
const DomainStrategy$json = {
  '1': 'DomainStrategy',
  '2': [
    {'1': 'as_is', '2': 0},
    {'1': 'prefer_ipv4', '2': 1},
    {'1': 'prefer_ipv6', '2': 2},
    {'1': 'ipv4_only', '2': 3},
    {'1': 'ipv6_only', '2': 4},
  ],
};

/// Descriptor for `DomainStrategy`. Decode as a `google.protobuf.EnumDescriptorProto`.
final $typed_data.Uint8List domainStrategyDescriptor = $convert.base64Decode(
    'Cg5Eb21haW5TdHJhdGVneRIJCgVhc19pcxAAEg8KC3ByZWZlcl9pcHY0EAESDwoLcHJlZmVyX2'
    'lwdjYQAhINCglpcHY0X29ubHkQAxINCglpcHY2X29ubHkQBA==');

@$core.Deprecated('Use martenOptionsDescriptor instead')
const MartenOptions$json = {
  '1': 'MartenOptions',
  '2': [
    {'1': 'enable_full_config', '3': 1, '4': 1, '5': 8, '10': 'enableFullConfig'},
    {'1': 'log_level', '3': 2, '4': 1, '5': 9, '10': 'logLevel'},
    {'1': 'log_file', '3': 3, '4': 1, '5': 9, '10': 'logFile'},
    {'1': 'enable_clash_api', '3': 4, '4': 1, '5': 8, '10': 'enableClashApi'},
    {'1': 'clash_api_port', '3': 5, '4': 1, '5': 13, '10': 'clashApiPort'},
    {'1': 'web_secret', '3': 6, '4': 1, '5': 9, '10': 'webSecret'},
    {'1': 'region', '3': 7, '4': 1, '5': 9, '10': 'region'},
    {'1': 'block_ads', '3': 8, '4': 1, '5': 8, '10': 'blockAds'},
    {'1': 'use_xray_core_when_possible', '3': 9, '4': 1, '5': 8, '10': 'useXrayCoreWhenPossible'},
    {'1': 'rules', '3': 10, '4': 3, '5': 11, '6': '.martenoptions.Rule', '10': 'rules'},
    {'1': 'mux', '3': 13, '4': 1, '5': 11, '6': '.martenoptions.MuxOptions', '10': 'mux'},
    {'1': 'tls_tricks', '3': 14, '4': 1, '5': 11, '6': '.martenoptions.TLSTricks', '10': 'tlsTricks'},
    {'1': 'dns_options', '3': 15, '4': 1, '5': 11, '6': '.martenoptions.DNSOptions', '10': 'dnsOptions'},
    {'1': 'inbound_options', '3': 16, '4': 1, '5': 11, '6': '.martenoptions.InboundOptions', '10': 'inboundOptions'},
    {'1': 'url_test_options', '3': 17, '4': 1, '5': 11, '6': '.martenoptions.URLTestOptions', '10': 'urlTestOptions'},
    {'1': 'route_options', '3': 18, '4': 1, '5': 11, '6': '.martenoptions.RouteOptions', '10': 'routeOptions'},
  ],
  '9': [
    {'1': 11, '2': 12},
    {'1': 12, '2': 13},
  ],
};

/// Descriptor for `MartenOptions`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List martenOptionsDescriptor = $convert.base64Decode(
    'Cg1NYXJ0ZW5PcHRpb25zEiwKEmVuYWJsZV9mdWxsX2NvbmZpZxgBIAEoCFIQZW5hYmxlRnVsbE'
    'NvbmZpZxIbCglsb2dfbGV2ZWwYAiABKAlSCGxvZ0xldmVsEhkKCGxvZ19maWxlGAMgASgJUgds'
    'b2dGaWxlEigKEGVuYWJsZV9jbGFzaF9hcGkYBCABKAhSDmVuYWJsZUNsYXNoQXBpEiQKDmNsYX'
    'NoX2FwaV9wb3J0GAUgASgNUgxjbGFzaEFwaVBvcnQSHQoKd2ViX3NlY3JldBgGIAEoCVIJd2Vi'
    'U2VjcmV0EhYKBnJlZ2lvbhgHIAEoCVIGcmVnaW9uEhsKCWJsb2NrX2FkcxgIIAEoCFIIYmxvY2'
    'tBZHMSPAobdXNlX3hyYXlfY29yZV93aGVuX3Bvc3NpYmxlGAkgASgIUhd1c2VYcmF5Q29yZVdo'
    'ZW5Qb3NzaWJsZRIpCgVydWxlcxgKIAMoCzITLm1hcnRlbm9wdGlvbnMuUnVsZVIFcnVsZXMSKw'
    'oDbXV4GA0gASgLMhkubWFydGVub3B0aW9ucy5NdXhPcHRpb25zUgNtdXgSNwoKdGxzX3RyaWNr'
    'cxgOIAEoCzIYLm1hcnRlbm9wdGlvbnMuVExTVHJpY2tzUgl0bHNUcmlja3MSOgoLZG5zX29wdG'
    'lvbnMYDyABKAsyGS5tYXJ0ZW5vcHRpb25zLkROU09wdGlvbnNSCmRuc09wdGlvbnMSRgoPaW5i'
    'b3VuZF9vcHRpb25zGBAgASgLMh0ubWFydGVub3B0aW9ucy5JbmJvdW5kT3B0aW9uc1IOaW5ib3'
    'VuZE9wdGlvbnMSRwoQdXJsX3Rlc3Rfb3B0aW9ucxgRIAEoCzIdLm1hcnRlbm9wdGlvbnMuVVJM'
    'VGVzdE9wdGlvbnNSDnVybFRlc3RPcHRpb25zEkAKDXJvdXRlX29wdGlvbnMYEiABKAsyGy5tYX'
    'J0ZW5vcHRpb25zLlJvdXRlT3B0aW9uc1IMcm91dGVPcHRpb25zSgQICxAMSgQIDBAN');

@$core.Deprecated('Use intRangeDescriptor instead')
const IntRange$json = {
  '1': 'IntRange',
  '2': [
    {'1': 'from', '3': 1, '4': 1, '5': 5, '10': 'from'},
    {'1': 'to', '3': 2, '4': 1, '5': 5, '10': 'to'},
  ],
};

/// Descriptor for `IntRange`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List intRangeDescriptor = $convert.base64Decode(
    'CghJbnRSYW5nZRISCgRmcm9tGAEgASgFUgRmcm9tEg4KAnRvGAIgASgFUgJ0bw==');

@$core.Deprecated('Use dNSOptionsDescriptor instead')
const DNSOptions$json = {
  '1': 'DNSOptions',
  '2': [
    {'1': 'remote_dns_address', '3': 1, '4': 1, '5': 9, '10': 'remoteDnsAddress'},
    {'1': 'remote_dns_domain_strategy', '3': 2, '4': 1, '5': 14, '6': '.martenoptions.DomainStrategy', '10': 'remoteDnsDomainStrategy'},
    {'1': 'direct_dns_address', '3': 3, '4': 1, '5': 9, '10': 'directDnsAddress'},
    {'1': 'direct_dns_domain_strategy', '3': 4, '4': 1, '5': 14, '6': '.martenoptions.DomainStrategy', '10': 'directDnsDomainStrategy'},
    {'1': 'independent_dns_cache', '3': 5, '4': 1, '5': 8, '10': 'independentDnsCache'},
    {'1': 'enable_fake_dns', '3': 6, '4': 1, '5': 8, '10': 'enableFakeDns'},
    {'1': 'enable_dns_routing', '3': 7, '4': 1, '5': 8, '10': 'enableDnsRouting'},
  ],
};

/// Descriptor for `DNSOptions`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List dNSOptionsDescriptor = $convert.base64Decode(
    'CgpETlNPcHRpb25zEiwKEnJlbW90ZV9kbnNfYWRkcmVzcxgBIAEoCVIQcmVtb3RlRG5zQWRkcm'
    'VzcxJaChpyZW1vdGVfZG5zX2RvbWFpbl9zdHJhdGVneRgCIAEoDjIdLm1hcnRlbm9wdGlvbnMu'
    'RG9tYWluU3RyYXRlZ3lSF3JlbW90ZURuc0RvbWFpblN0cmF0ZWd5EiwKEmRpcmVjdF9kbnNfYW'
    'RkcmVzcxgDIAEoCVIQZGlyZWN0RG5zQWRkcmVzcxJaChpkaXJlY3RfZG5zX2RvbWFpbl9zdHJh'
    'dGVneRgEIAEoDjIdLm1hcnRlbm9wdGlvbnMuRG9tYWluU3RyYXRlZ3lSF2RpcmVjdERuc0RvbW'
    'FpblN0cmF0ZWd5EjIKFWluZGVwZW5kZW50X2Ruc19jYWNoZRgFIAEoCFITaW5kZXBlbmRlbnRE'
    'bnNDYWNoZRImCg9lbmFibGVfZmFrZV9kbnMYBiABKAhSDWVuYWJsZUZha2VEbnMSLAoSZW5hYm'
    'xlX2Ruc19yb3V0aW5nGAcgASgIUhBlbmFibGVEbnNSb3V0aW5n');

@$core.Deprecated('Use inboundOptionsDescriptor instead')
const InboundOptions$json = {
  '1': 'InboundOptions',
  '2': [
    {'1': 'enable_tun', '3': 1, '4': 1, '5': 8, '10': 'enableTun'},
    {'1': 'enable_tun_service', '3': 2, '4': 1, '5': 8, '10': 'enableTunService'},
    {'1': 'set_system_proxy', '3': 3, '4': 1, '5': 8, '10': 'setSystemProxy'},
    {'1': 'mixed_port', '3': 4, '4': 1, '5': 13, '10': 'mixedPort'},
    {'1': 'tproxy_port', '3': 5, '4': 1, '5': 13, '10': 'tproxyPort'},
    {'1': 'local_dns_port', '3': 6, '4': 1, '5': 13, '10': 'localDnsPort'},
    {'1': 'mtu', '3': 7, '4': 1, '5': 13, '10': 'mtu'},
    {'1': 'strict_route', '3': 8, '4': 1, '5': 8, '10': 'strictRoute'},
    {'1': 'tun_stack', '3': 9, '4': 1, '5': 9, '10': 'tunStack'},
  ],
};

/// Descriptor for `InboundOptions`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List inboundOptionsDescriptor = $convert.base64Decode(
    'Cg5JbmJvdW5kT3B0aW9ucxIdCgplbmFibGVfdHVuGAEgASgIUgllbmFibGVUdW4SLAoSZW5hYm'
    'xlX3R1bl9zZXJ2aWNlGAIgASgIUhBlbmFibGVUdW5TZXJ2aWNlEigKEHNldF9zeXN0ZW1fcHJv'
    'eHkYAyABKAhSDnNldFN5c3RlbVByb3h5Eh0KCm1peGVkX3BvcnQYBCABKA1SCW1peGVkUG9ydB'
    'IfCgt0cHJveHlfcG9ydBgFIAEoDVIKdHByb3h5UG9ydBIkCg5sb2NhbF9kbnNfcG9ydBgGIAEo'
    'DVIMbG9jYWxEbnNQb3J0EhAKA210dRgHIAEoDVIDbXR1EiEKDHN0cmljdF9yb3V0ZRgIIAEoCF'
    'ILc3RyaWN0Um91dGUSGwoJdHVuX3N0YWNrGAkgASgJUgh0dW5TdGFjaw==');

@$core.Deprecated('Use uRLTestOptionsDescriptor instead')
const URLTestOptions$json = {
  '1': 'URLTestOptions',
  '2': [
    {'1': 'connection_test_url', '3': 1, '4': 1, '5': 9, '10': 'connectionTestUrl'},
    {'1': 'url_test_interval', '3': 2, '4': 1, '5': 3, '10': 'urlTestInterval'},
  ],
};

/// Descriptor for `URLTestOptions`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List uRLTestOptionsDescriptor = $convert.base64Decode(
    'Cg5VUkxUZXN0T3B0aW9ucxIuChNjb25uZWN0aW9uX3Rlc3RfdXJsGAEgASgJUhFjb25uZWN0aW'
    '9uVGVzdFVybBIqChF1cmxfdGVzdF9pbnRlcnZhbBgCIAEoA1IPdXJsVGVzdEludGVydmFs');

@$core.Deprecated('Use routeOptionsDescriptor instead')
const RouteOptions$json = {
  '1': 'RouteOptions',
  '2': [
    {'1': 'resolve_destination', '3': 1, '4': 1, '5': 8, '10': 'resolveDestination'},
    {'1': 'ipv6_mode', '3': 2, '4': 1, '5': 14, '6': '.martenoptions.DomainStrategy', '10': 'ipv6Mode'},
    {'1': 'bypass_lan', '3': 3, '4': 1, '5': 8, '10': 'bypassLan'},
    {'1': 'allow_connection_from_lan', '3': 4, '4': 1, '5': 8, '10': 'allowConnectionFromLan'},
  ],
};

/// Descriptor for `RouteOptions`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List routeOptionsDescriptor = $convert.base64Decode(
    'CgxSb3V0ZU9wdGlvbnMSLwoTcmVzb2x2ZV9kZXN0aW5hdGlvbhgBIAEoCFIScmVzb2x2ZURlc3'
    'RpbmF0aW9uEjoKCWlwdjZfbW9kZRgCIAEoDjIdLm1hcnRlbm9wdGlvbnMuRG9tYWluU3RyYXRl'
    'Z3lSCGlwdjZNb2RlEh0KCmJ5cGFzc19sYW4YAyABKAhSCWJ5cGFzc0xhbhI5ChlhbGxvd19jb2'
    '5uZWN0aW9uX2Zyb21fbGFuGAQgASgIUhZhbGxvd0Nvbm5lY3Rpb25Gcm9tTGFu');

@$core.Deprecated('Use tLSTricksDescriptor instead')
const TLSTricks$json = {
  '1': 'TLSTricks',
  '2': [
    {'1': 'enable_fragment', '3': 1, '4': 1, '5': 8, '10': 'enableFragment'},
    {'1': 'fragment_size', '3': 2, '4': 1, '5': 11, '6': '.martenoptions.IntRange', '10': 'fragmentSize'},
    {'1': 'fragment_sleep', '3': 3, '4': 1, '5': 11, '6': '.martenoptions.IntRange', '10': 'fragmentSleep'},
    {'1': 'mixed_sni_case', '3': 4, '4': 1, '5': 8, '10': 'mixedSniCase'},
    {'1': 'enable_padding', '3': 5, '4': 1, '5': 8, '10': 'enablePadding'},
    {'1': 'padding_size', '3': 6, '4': 1, '5': 11, '6': '.martenoptions.IntRange', '10': 'paddingSize'},
  ],
};

/// Descriptor for `TLSTricks`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List tLSTricksDescriptor = $convert.base64Decode(
    'CglUTFNUcmlja3MSJwoPZW5hYmxlX2ZyYWdtZW50GAEgASgIUg5lbmFibGVGcmFnbWVudBI8Cg'
    '1mcmFnbWVudF9zaXplGAIgASgLMhcubWFydGVub3B0aW9ucy5JbnRSYW5nZVIMZnJhZ21lbnRT'
    'aXplEj4KDmZyYWdtZW50X3NsZWVwGAMgASgLMhcubWFydGVub3B0aW9ucy5JbnRSYW5nZVINZn'
    'JhZ21lbnRTbGVlcBIkCg5taXhlZF9zbmlfY2FzZRgEIAEoCFIMbWl4ZWRTbmlDYXNlEiUKDmVu'
    'YWJsZV9wYWRkaW5nGAUgASgIUg1lbmFibGVQYWRkaW5nEjoKDHBhZGRpbmdfc2l6ZRgGIAEoCz'
    'IXLm1hcnRlbm9wdGlvbnMuSW50UmFuZ2VSC3BhZGRpbmdTaXpl');

@$core.Deprecated('Use muxOptionsDescriptor instead')
const MuxOptions$json = {
  '1': 'MuxOptions',
  '2': [
    {'1': 'enable', '3': 1, '4': 1, '5': 8, '10': 'enable'},
    {'1': 'padding', '3': 2, '4': 1, '5': 8, '10': 'padding'},
    {'1': 'max_streams', '3': 3, '4': 1, '5': 5, '10': 'maxStreams'},
    {'1': 'protocol', '3': 4, '4': 1, '5': 9, '10': 'protocol'},
  ],
};

/// Descriptor for `MuxOptions`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List muxOptionsDescriptor = $convert.base64Decode(
    'CgpNdXhPcHRpb25zEhYKBmVuYWJsZRgBIAEoCFIGZW5hYmxlEhgKB3BhZGRpbmcYAiABKAhSB3'
    'BhZGRpbmcSHwoLbWF4X3N0cmVhbXMYAyABKAVSCm1heFN0cmVhbXMSGgoIcHJvdG9jb2wYBCAB'
    'KAlSCHByb3RvY29s');

@$core.Deprecated('Use ruleDescriptor instead')
const Rule$json = {
  '1': 'Rule',
  '2': [
    {'1': 'rule_set_url', '3': 1, '4': 1, '5': 9, '10': 'ruleSetUrl'},
    {'1': 'domains', '3': 2, '4': 1, '5': 9, '10': 'domains'},
    {'1': 'ip', '3': 3, '4': 1, '5': 9, '10': 'ip'},
    {'1': 'port', '3': 4, '4': 1, '5': 9, '10': 'port'},
    {'1': 'network', '3': 5, '4': 1, '5': 9, '10': 'network'},
    {'1': 'protocol', '3': 6, '4': 1, '5': 9, '10': 'protocol'},
    {'1': 'outbound', '3': 7, '4': 1, '5': 9, '10': 'outbound'},
  ],
};

/// Descriptor for `Rule`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List ruleDescriptor = $convert.base64Decode(
    'CgRSdWxlEiAKDHJ1bGVfc2V0X3VybBgBIAEoCVIKcnVsZVNldFVybBIYCgdkb21haW5zGAIgAS'
    'gJUgdkb21haW5zEg4KAmlwGAMgASgJUgJpcBISCgRwb3J0GAQgASgJUgRwb3J0EhgKB25ldHdv'
    'cmsYBSABKAlSB25ldHdvcmsSGgoIcHJvdG9jb2wYBiABKAlSCHByb3RvY29sEhoKCG91dGJvdW'
    '5kGAcgASgJUghvdXRib3VuZA==');

