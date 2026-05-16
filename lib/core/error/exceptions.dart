class ProviderException implements Exception {
  final String message;
  final Object? cause;
  ProviderException(this.message, [this.cause]);
  @override
  String toString() =>
      'ProviderException: $message${cause != null ? ' ($cause)' : ''}';
}

class JsRuntimeException implements Exception {
  final String message;
  final Object? cause;
  JsRuntimeException(this.message, [this.cause]);
  @override
  String toString() =>
      'JsRuntimeException: $message${cause != null ? ' ($cause)' : ''}';
}

class NetworkException implements Exception {
  final String message;
  final int? statusCode;
  NetworkException(this.message, {this.statusCode});
  @override
  String toString() =>
      'NetworkException: $message${statusCode != null ? ' [$statusCode]' : ''}';
}

class CacheException implements Exception {
  final String message;
  CacheException(this.message);
  @override
  String toString() => 'CacheException: $message';
}

class ParseException implements Exception {
  final String message;
  ParseException(this.message);
  @override
  String toString() => 'ParseException: $message';
}
