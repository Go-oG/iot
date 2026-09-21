
/// 角色，* 表示任意角色
enum Role {
  all('*'),
  user('user'),
  admin('admin'),
  factory('factory');

  final String wireName;

  const Role(this.wireName);

  static Role valueOf(String value) {
    for (final v in values) {
      if (v.wireName == value) {
        return v;
      }
    }
    throw FormatException('Unsupported role: $value');
  }
}

class PermissionSpec {
  final List<Role>? read;
  final List<Role>? write;
  final List<Role>? notify;

  const PermissionSpec({this.read, this.write, this.notify});

  factory PermissionSpec.fromJson(Map<String, dynamic> json) {
    return PermissionSpec(
      read: _roleList(json['read']),
      write: _roleList(json['write']),
      notify: _roleList(json['notify']),
    );
  }

  bool allowsRead(Role role) => _allows(read, role);

  bool allowsWrite(Role role) => _allows(write, role);

  bool allowsNotify(Role role) => _allows(notify, role);

  bool _allows(List<Role>? roles, Role role) {
    if (roles == null) return true;
    return roles.contains(Role.all) || roles.contains(role);
  }

  Map<String, dynamic> toJson() => {
    if (read != null) 'read': [for (final role in read!) role.wireName],
    if (write != null) 'write': [for (final role in write!) role.wireName],
    if (notify != null) 'notify': [for (final role in notify!) role.wireName],
  };
}

List<Role>? _roleList(dynamic value) {
  if (value == null) return null;
  final roles = (value as List).map((e) => Role.valueOf(e.toString())).toList(growable: false);
  if (roles.isEmpty) {
    throw FormatException('permission role list must not be empty');
  }
  if (roles.toSet().length != roles.length) {
    throw FormatException('permission role list contains duplicates');
  }
  return roles;
}
