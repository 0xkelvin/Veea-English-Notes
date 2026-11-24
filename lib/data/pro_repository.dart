import 'dart:convert';
import 'package:flutter/services.dart';
import '../core/config/app_config.dart';
import 'remote/go/api_client.dart';

class ProStoreState {
  const ProStoreState({
    this.hasPro = false,
    this.hasLifetime = false,
    this.price,
    this.transactions = const [],
    this.pendingTransactions = const [],
    this.outcome,
  });
  final bool hasPro;
  final bool hasLifetime;
  final String? price;
  final List<String> transactions;
  final List<String> pendingTransactions;
  final String? outcome;
  factory ProStoreState.fromMap(Map<dynamic, dynamic>? data) => ProStoreState(
    hasPro: data?['hasPro'] == true,
    hasLifetime: data?['hasLifetime'] == true,
    pendingTransactions: (data?['pendingTransactions'] as List? ?? const [])
        .whereType<String>()
        .toList(),
    price: data?['price'] as String?,
    transactions: (data?['transactions'] as List? ?? const [])
        .whereType<String>()
        .toList(),
    outcome: data?['outcome'] as String?,
  );
}

/// StoreKit verifies device entitlements; Go verifies and records account ownership.
/// No notebook content is included in either transport.
class ProRepository {
  ProRepository({required this.client, MethodChannel? channel})
    : channel = channel ?? const MethodChannel('app.veea.english/purchases');
  final GoApiClient client;
  final MethodChannel channel;
  void Function()? onChange;
  void listen() => channel.setMethodCallHandler((call) async {
    if (call.method == 'onProChanged') onChange?.call();
  });
  Future<ProStoreState> configure(
    String? owner, {
    DateTime? serverUntil,
    bool clearServer = false,
    bool? serverLifetime,
    bool loadProduct = true,
  }) async => ProStoreState.fromMap(
    await channel.invokeMapMethod<dynamic, dynamic>('configure', {
      'productID': AppConfig.appleProProductId,
      'accountID': owner,
      if (serverUntil != null)
        'serverUntil': serverUntil.millisecondsSinceEpoch / 1000,
      'clearServer': clearServer,
      'serverLifetime': ?serverLifetime,
      'loadProduct': loadProduct && !AppConfig.isFreeLaunch,
    }),
  );
  Future<ProStoreState> purchase() async => ProStoreState.fromMap(
    await channel.invokeMapMethod<dynamic, dynamic>('purchase'),
  );
  Future<ProStoreState> restore() async => ProStoreState.fromMap(
    await channel.invokeMapMethod<dynamic, dynamic>('restore'),
  );
  Future<void> recordVerification(String id, {required bool revoked}) =>
      channel.invokeMethod<void>('recordVerification', {
        'transactionID': id,
        'revoked': revoked,
      });
  Future<void> finish(String id) =>
      channel.invokeMethod<void>('finish', {'transactionID': id});
  Future<Map<String, Object?>> entitlement(String owner) async =>
      GoApiClient.decode(
        await client.raw('GET', '/v1/me/entitlements', expectedUserId: owner),
      );
  Future<Map<String, Object?>> claim(String owner, String id) async =>
      GoApiClient.decode(
        await client.raw(
          'POST',
          '/v1/me/purchases/apple',
          expectedUserId: owner,
          body: Uint8List.fromList(
            utf8.encode(jsonEncode({'transaction_id': id})),
          ),
        ),
      );
}
