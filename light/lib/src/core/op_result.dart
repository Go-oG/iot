final class OpResult {
  final bool success;
  final String message;

  OpResult.success([this.message = '']) : success = true;

  OpResult.fail(this.message) : success = false;
}
