import 'dart:convert';
import 'dart:typed_data';
import '../remote/go/api_client.dart';

class CartridgeMetadata {
  CartridgeMetadata(this.json);
  final Map<String, Object?> json;
  String get id => json['id']! as String;
  String get title => json['title']! as String;
  String get plan => json['required_plan']! as String;
  int get version => json['version']! as int;
  int get installedVersion => json['installed_version']! as int;
  int get wordCount => json['word_count']! as int;
}

abstract interface class CartridgeApi {
  Future<List<CartridgeMetadata>> catalog();
  Future<void> download(String id, int version);
  Future<Map<String, Object?>> capacity();
  Future<Map<String, Object?>> install(
    String id,
    int version,
    String exactBody,
  );
}

class GoCartridgeApi implements CartridgeApi {
  GoCartridgeApi(this.client);
  final GoApiClient client;
  String _path(String id, int version) =>
      '/v1/cartridges/${Uri.encodeComponent(id)}/versions/$version';
  @override
  Future<List<CartridgeMetadata>> catalog() async =>
      ((await client.get('/v1/cartridges'))['cartridges']! as List)
          .map((e) => CartridgeMetadata((e as Map).cast<String, Object?>()))
          .toList();
  @override
  Future<void> download(String id, int version) async {
    await client.get('${_path(id, version)}/content');
  }

  @override
  Future<Map<String, Object?>> capacity() =>
      client.get('/v1/learning/sync/state');
  @override
  Future<Map<String, Object?>> install(
    String id,
    int version,
    String exactBody,
  ) async {
    final response = await client.raw(
      'POST',
      '${_path(id, version)}/install',
      body: Uint8List.fromList(utf8.encode(exactBody)),
    );
    return GoApiClient.decode(response);
  }
}
