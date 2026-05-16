import 'package:equatable/equatable.dart';

abstract class Failure extends Equatable {
  final String message;
  const Failure(this.message);
  @override
  List<Object?> get props => [message];
}

class ProviderFailure extends Failure {
  const ProviderFailure(super.message);
}

class JsRuntimeFailure extends Failure {
  const JsRuntimeFailure(super.message);
}

class NetworkFailure extends Failure {
  final int? statusCode;
  const NetworkFailure(super.message, {this.statusCode});
  @override
  List<Object?> get props => [message, statusCode];
}

class CacheFailure extends Failure {
  const CacheFailure(super.message);
}

class ParseFailure extends Failure {
  const ParseFailure(super.message);
}

class UnknownFailure extends Failure {
  const UnknownFailure(super.message);
}
