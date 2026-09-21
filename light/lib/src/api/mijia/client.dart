import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math';

import 'package:dio/dio.dart';

import 'auth_store.dart';
import 'crypto.dart';
import 'errors.dart';

/// Receives debug/progress messages. Defaults to dropping them.
typedef MijiaLogger = void Function(String message);

/// Called with the QR code to display when a login is required.
///
/// [loginUrl] is the string to encode into a QR code; [qrImageUrl] is a hosted
/// image of the same code, offered as a fallback.
typedef MijiaQrCodeHandler = void Function(String loginUrl, String qrImageUrl);

/// Client for the MiJia (米家) cloud API.
///
/// Every remote endpoint the Python `mijia-api` library uses is implemented
/// here on top of `dio`. One instance owns one account's [authData]; requests
/// are signed with SHA-1 and encrypted with RC4 exactly as the MiJia app does.
///
/// Endpoints reached:
///
/// * `https://account.xiaomi.com/pass/serviceLogin` — token refresh and login
///   redirection
/// * `https://account.xiaomi.com/longPolling/loginUrl` — QR login
/// * `https://api.mijia.tech/app` — the encrypted app API
///
/// ```dart
/// final api = MijiaApi();
/// if (!await api.checkAvailable()) {
///   await api.qrLogin(onQrCode: (url, _) => showQrCode(url));
/// }
/// final homes = await api.getHomesList();
/// ```
class MijiaApi {
  MijiaApi({
    Dio? dio,
    MijiaAuthStore? authStore,
    String? authDataPath,
    String? locale,
    String? timeZoneId,
    this._random,
    this.apiBaseUrl = defaultApiBaseUrl,
    this.loginUrl = defaultLoginUrl,
    this.serviceLoginUrl = defaultServiceLoginUrl,
    this.logger,
    Map<String, dynamic>? authData,
  })  : locale = _normalizeLocale(locale),
        _store = authStore ??
            (authDataPath != null
                ? FileAuthStore.forPath(authDataPath)
                : FileAuthStore.defaultLocation()),
        _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 30),
                receiveTimeout: const Duration(seconds: 60),
                // Failures are reported in the body, and the login flow reads
                // raw status codes itself, so dio must never throw on them.
                validateStatus: (_) => true,
                responseType: ResponseType.plain,
              ),
            ),
        authData = authData ?? <String, dynamic>{} {
    if (timeZoneId != null) _timeZoneId = timeZoneId;
  }

  /// Builds a client and loads credentials already held by its auth store.
  ///
  /// The plain constructor starts from an empty [authData] because it cannot
  /// await; this factory reproduces the Python behaviour of reading
  /// `auth.json` during construction, so a saved session needs no extra step.
  static Future<MijiaApi> create({
    Dio? dio,
    MijiaAuthStore? authStore,
    String? authDataPath,
    String? locale,
    String? timeZoneId,
    Random? random,
    String apiBaseUrl = defaultApiBaseUrl,
    String loginUrl = defaultLoginUrl,
    String serviceLoginUrl = defaultServiceLoginUrl,
    MijiaLogger? logger,
    Map<String, dynamic>? authData,
  }) async {
    final api = MijiaApi(
      dio: dio,
      authStore: authStore,
      authDataPath: authDataPath,
      locale: locale,
      timeZoneId: timeZoneId,
      random: random,
      apiBaseUrl: apiBaseUrl,
      loginUrl: loginUrl,
      serviceLoginUrl: serviceLoginUrl,
      logger: logger,
      authData: authData,
    );
    await api.loadStoredAuth();
    return api;
  }

  static const String defaultApiBaseUrl = 'https://api.mijia.tech/app';
  static const String defaultLoginUrl =
      'https://account.xiaomi.com/longPolling/loginUrl';
  static const String defaultServiceLoginUrl =
      'https://account.xiaomi.com/pass/serviceLogin?_json=true&sid=mijia';

  /// Base URL of the encrypted app API.
  final String apiBaseUrl;

  /// Endpoint that hands out the QR login session.
  final String loginUrl;

  /// Endpoint that resolves the account's login location.
  final String serviceLoginUrl;

  /// Locale in `zh_CN` form, sent as `_locale` and inside cookies.
  final String locale;

  final MijiaAuthStore _store;
  final Dio _dio;
  final Random? _random;

  /// Debug sink; a no-op when unset.
  final MijiaLogger? logger;

  /// Token blob: `passToken`, `userId`, `cUserId`, `serviceToken`,
  /// `ssecurity`, `ua`, `deviceId`, `expireTime`, …
  Map<String, dynamic> authData;

  /// Cookies seen during the current login session, mirroring the cookie jar
  /// of a `requests.Session`.
  final Map<String, String> _cookieJar = <String, String>{};

  bool? _availableCache;
  int _availableCacheTime = 0;
  String? _timeZoneId;

  /// Two-letter country code derived from [locale], e.g. `CN`.
  String get countryCode {
    final parts = locale.split('_');
    return parts.length > 1 && parts[1].isNotEmpty ? parts[1] : 'CN';
  }

  /// IANA timezone name written into the session cookie.
  ///
  /// Dart exposes no portable zone database, so this prefers the `TZ`
  /// environment variable and otherwise falls back to the platform's
  /// abbreviation. That abbreviation is localised on some systems (Windows
  /// reports `中国标准时间`), which is neither a valid IANA name nor legal in
  /// an HTTP header, so the last resort is a fixed-offset `Etc/GMT±N` zone
  /// derived from the current offset. Pass `timeZoneId` to the constructor to
  /// skip the guesswork entirely.
  String get timeZoneId => _timeZoneId ??= _resolveTimeZoneId();

  set timeZoneId(String value) => _timeZoneId = value;

  // ---------------------------------------------------------------------------
  // Session state
  // ---------------------------------------------------------------------------

  /// Whether [authData] holds a usable token.
  ///
  /// Mirrors the Python `available` property: cheap shape checks first, then a
  /// real request whose outcome is cached for 60 seconds.
  Future<bool> checkAvailable() async {
    if (authData.isEmpty) return false;
    for (final key in const [
      'ua',
      'ssecurity',
      'userId',
      'cUserId',
      'serviceToken',
    ]) {
      if (!authData.containsKey(key)) return false;
    }

    final now = _nowSeconds;
    if (now - _availableCacheTime < 60) {
      logger?.call('使用缓存的available结果: $_availableCache');
      return _availableCache ?? false;
    }

    try {
      await checkNewMsg(refreshToken: false);
    } on Object {
      _availableCache = null;
      _availableCacheTime = 0;
      return false;
    }

    _availableCache = true;
    _availableCacheTime = now;
    return true;
  }

  /// Random per-install identifier, generated on first use.
  String get passO =>
      authData['pass_o'] as String? ??
      (authData['pass_o'] = _randomString('0123456789abcdef', 16));

  /// MiJia app user agent identifying this client.
  String get userAgent {
    final existing = authData['ua'] as String?;
    if (existing != null) return existing;
    const hex = '0123456789ABCDEF';
    final id1 = _randomString(hex, 40);
    final id2 = _randomString(hex, 32);
    final id3 = _randomString(hex, 32);
    final id4 = _randomString(hex, 40);
    return authData['ua'] =
        'Android-15-11.0.701-Xiaomi-23046RP50C-OS2.0.212.0.VMYCNXM-'
            '$id1-$countryCode-$id3-$id2-SmartHome-MI_APP_STORE-'
            '$id1|$id4|$passO-64';
  }

  /// Passport device id, generated on first use.
  String get deviceId =>
      authData['deviceId'] as String? ??
      (authData['deviceId'] = _randomString(
          '0123456789abcdefghijklmnopqrstuvwxyz'
          'ABCDEFGHIJKLMNOPQRSTUVWXYZ_-',
          16));

  // ---------------------------------------------------------------------------
  // Login
  // ---------------------------------------------------------------------------

  /// QR-code login. Alias of [qrLogin], matching the Python `login()`.
  Future<Map<String, dynamic>> login({MijiaQrCodeHandler? onQrCode}) =>
      qrLogin(onQrCode: onQrCode);

  /// Runs the full QR login flow, returning and persisting the auth blob.
  ///
  /// If the stored token can still be refreshed no QR code is shown and the
  /// existing [authData] is returned unchanged.
  Future<Map<String, dynamic>> qrLogin({MijiaQrCodeHandler? onQrCode}) async {
    final loginData = await getQrLoginData();
    if (loginData['refreshed'] == true) {
      return authData;
    }
    final qrLoginUrl = loginData['loginUrl'] as String? ?? '';
    final qr = loginData['qr'] as String? ?? '';
    logger?.call('请使用米家APP扫描二维码');
    if (onQrCode != null) {
      onQrCode(qrLoginUrl, qr);
    } else {
      logger?.call('也可以访问链接查看二维码图片: $qr');
    }
    return completeQrLogin(loginData);
  }

  /// Fetches the QR login session without waiting for a scan.
  ///
  /// Returns `{'refreshed': true}` when an existing token was refreshed
  /// instead, otherwise login data containing `loginUrl`, `qr` and `lp`.
  Future<Map<String, dynamic>> getQrLoginData() async {
    final locationData = await _getLocation();
    if (locationData['code'] == 0 && locationData['message'] == '刷新Token成功') {
      await _saveAuthData();
      _initSession();
      logger?.call('刷新Token成功，无需登录');
      return <String, dynamic>{'refreshed': true};
    }

    final params = <String, dynamic>{
      ...locationData,
      'theme': '',
      'bizDeviceType': '',
      '_hasLogo': 'false',
      '_qrsize': '240',
      '_dc': '${DateTime.now().millisecondsSinceEpoch}',
    };
    final res = await _get('$loginUrl?${_urlEncode(params)}',
        headers: _loginFlowHeaders);
    return _handleRet(res);
  }

  /// Long-polls [loginData] until the user scans, then stores the credentials.
  ///
  /// Gives up after two minutes, matching the Python client's `timeout=120`.
  Future<Map<String, dynamic>> completeQrLogin(
    Map<String, dynamic> loginData,
  ) async {
    final lp = loginData['lp'] as String?;
    if (lp == null) {
      throw const MijiaLoginException(-1, '登录数据缺少 lp 字段');
    }

    final jar = <String, String>{};
    final Response<dynamic> lpRes;
    try {
      lpRes = await _get(
        lp,
        headers: _loginFlowHeaders,
        jar: jar,
        receiveTimeout: const Duration(seconds: 120),
      );
    } on DioException catch (e) {
      if (e.type == DioExceptionType.receiveTimeout ||
          e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.sendTimeout) {
        throw const MijiaLoginException(-1, '超时，请重试');
      }
      throw MijiaLoginException(-1, e.message ?? '$e');
    }

    final lpData = _handleRet(lpRes);
    for (final key in const [
      'psecurity',
      'nonce',
      'ssecurity',
      'passToken',
      'userId',
      'cUserId',
    ]) {
      authData[key] = lpData[key];
    }

    final callbackUrl = lpData['location'] as String?;
    if (callbackUrl != null) {
      await _get(callbackUrl, headers: _loginFlowHeaders, jar: jar);
    }

    authData.addAll(jar);
    authData['expireTime'] =
        DateTime.now().add(const Duration(days: 30)).millisecondsSinceEpoch;

    await _saveAuthData();
    logger?.call('登录成功');
    _initSession();
    return authData;
  }

  /// Loads credentials from the [MijiaAuthStore] into [authData].
  ///
  /// Returns whether anything was stored. The plain constructor does not call
  /// this because it cannot await; use [MijiaApi.create] for the Python
  /// `auth_data_path` behaviour.
  Future<bool> loadStoredAuth() async {
    final stored = await _store.read();
    if (stored == null) return false;
    authData = stored;
    _initSession();
    return true;
  }

  /// Discards stored credentials, in memory and in the [MijiaAuthStore].
  Future<void> logout() async {
    authData = <String, dynamic>{};
    _availableCache = null;
    _availableCacheTime = 0;
    _cookieJar.clear();
    await _store.clear();
  }

  /// Resolves the account's login location, refreshing cookies when possible.
  Future<Map<String, dynamic>> _getLocation() async {
    final headers = <String, String>{
      'User-Agent': userAgent,
      'Connection': 'keep-alive',
      'Accept-Encoding': 'gzip',
      'Content-Type': 'application/x-www-form-urlencoded',
      'Cookie': 'deviceId=$deviceId;'
          'pass_o=$passO;'
          'passToken=${authData['passToken'] ?? ''};'
          'userId=${authData['userId'] ?? ''};'
          'cUserId=${authData['cUserId'] ?? ''};'
          'uLocale=$locale;',
    };

    final serviceRes = await _get(
      '$serviceLoginUrl&_locale=$locale',
      headers: headers,
    );
    final serviceData = _handleRet(serviceRes, verifyCode: false);
    final location = serviceData['location'] as String?;

    if (serviceData['code'] == 0 && location != null) {
      final res = await _get(location, headers: headers, jar: _cookieJar);
      if (res.statusCode == 200 && '${res.data}'.trim() == 'ok') {
        authData.addAll(_cookieJar);
        authData['ssecurity'] = serviceData['ssecurity'];
        return <String, dynamic>{'code': 0, 'message': '刷新Token成功'};
      }
    }

    if (location == null) {
      throw const MijiaLoginException(-1, '登录响应缺少 location 字段');
    }
    return _parseLocationQuery(location);
  }

  /// Ensures [authData] holds a valid token, refreshing it when possible.
  Future<Map<String, dynamic>> _refreshToken() async {
    if (await checkAvailable()) {
      logger?.call('Token 有效，无需刷新');
      return authData;
    }
    final locationData = await _getLocation();
    if (locationData['code'] == 0 && locationData['message'] == '刷新Token成功') {
      await _saveAuthData();
      _initSession();
      logger?.call('刷新Token成功');
      return authData;
    }
    throw const MijiaLoginException(-1, '刷新Token失败，请重新登录');
  }

  /// Rebuilds the per-session state `_init_session` resets in Python.
  void _initSession() => _cookieJar.clear();

  Future<void> _saveAuthData() async {
    authData['saveTime'] = DateTime.now().millisecondsSinceEpoch;
    await _store.write(authData);
  }

  // ---------------------------------------------------------------------------
  // Request plumbing
  // ---------------------------------------------------------------------------

  /// POSTs [data] to an arbitrary MiJia [uri], signing and encrypting it.
  ///
  /// Exposed so endpoints without a named wrapper stay reachable. Pass
  /// `refreshToken: false` to skip the availability probe, which is required
  /// when the call *is* the probe.
  Future<dynamic> request(
    String uri,
    Map<String, dynamic> data, {
    bool refreshToken = true,
  }) async {
    logger?.call('请求 URI: $uri，数据: $data');
    if (refreshToken) {
      await _refreshToken();
    }

    final ssecurity = authData['ssecurity'] as String?;
    if (ssecurity == null) {
      throw const MijiaLoginException(-1, '未登录，请先调用 login()');
    }

    final nonce = genNonce(random: _random);
    final signedNonce = getSignedNonce(ssecurity, nonce);
    final body = generateEncParams(
      uri,
      'POST',
      signedNonce,
      nonce,
      <String, String>{'data': jsonEncode(data)},
      ssecurity,
    );

    final res = await _dio.post<dynamic>(
      '$apiBaseUrl$uri',
      data: _urlEncode(body),
      options: _plainOptions(_sessionHeaders),
    );

    final text = _bodyText(res);
    Map<String, dynamic> retData;
    try {
      retData = _asJsonMap(jsonDecode(text));
    } on FormatException {
      retData = _asJsonMap(jsonDecode(decrypt(ssecurity, nonce, text)));
    }

    logger?.call('响应数据: $retData');
    final code = _asInt(retData['code']);
    if (code != 0 || !retData.containsKey('result')) {
      throw MijiaApiException(
        code,
        '${retData['message'] ?? retData['desc'] ?? '未知错误'}',
      );
    }
    return retData['result'];
  }

  /// Headers attached to every encrypted app-API request.
  Map<String, String> get _sessionHeaders => <String, String>{
        'User-Agent': userAgent,
        'accept-encoding': 'identity',
        'Content-Type': 'application/x-www-form-urlencoded',
        'miot-accept-encoding': 'GZIP',
        'miot-encrypt-algorithm': 'ENCRYPT-RC4',
        'x-xiaomi-protocal-flag-cli': 'PROTOCAL-HTTP2',
        'Cookie': _sessionCookie,
      };

  /// Cookie string mirroring `_init_session`, including the local timezone.
  String get _sessionCookie {
    final offset = DateTime.now().timeZoneOffset;
    final sign = offset.isNegative ? '-' : '+';
    final abs = offset.abs();
    final hh = abs.inHours.toString().padLeft(2, '0');
    final mm = (abs.inMinutes % 60).toString().padLeft(2, '0');
    return 'cUserId=${authData['cUserId']};'
        'yetAnotherServiceToken=${authData['serviceToken']};'
        'serviceToken=${authData['serviceToken']};'
        'timezone_id=$timeZoneId;'
        'timezone=GMT$sign$hh:$mm;'
        'is_daylight=${_zoneHasDaylightSaving ? 1 : 0};'
        'dst_offset=$_currentDstOffsetMs;'
        'channel=MI_APP_STORE;'
        'countryCode=$countryCode;'
        'PassportDeviceId=$deviceId;'
        'locale=$locale';
  }

  /// Headers used by the unencrypted passport/login endpoints.
  Map<String, String> get _loginFlowHeaders => <String, String>{
        'User-Agent': userAgent,
        'Accept-Encoding': 'gzip',
        'Content-Type': 'application/x-www-form-urlencoded',
        'Connection': 'keep-alive',
      };

  Options _plainOptions(
    Map<String, String> headers, {
    Duration? receiveTimeout,
  }) =>
      Options(
        headers: headers,
        responseType: ResponseType.plain,
        validateStatus: (_) => true,
        receiveTimeout: receiveTimeout,
      );

  /// GETs [url] following redirects by hand.
  ///
  /// Doing it manually is what lets cookies set on intermediate hops land in
  /// [jar], which is how `requests` populates its session jar.
  Future<Response<dynamic>> _get(
    String url, {
    required Map<String, String> headers,
    Map<String, String>? jar,
    Duration? receiveTimeout,
    int maxRedirects = 10,
  }) async {
    var current = url;
    for (var hop = 0; hop <= maxRedirects; hop++) {
      final res = await _dio.get<dynamic>(
        current,
        options: Options(
          headers: headers,
          responseType: ResponseType.plain,
          validateStatus: (_) => true,
          followRedirects: false,
          receiveTimeout: receiveTimeout,
        ),
      );
      if (jar != null) _mergeCookies(res, jar);

      final status = res.statusCode ?? 0;
      if (status < 300 || status >= 400) return res;

      final location = res.headers.value('location');
      if (location == null || location.isEmpty) return res;
      current = Uri.parse(current).resolve(location).toString();
    }
    throw MijiaLoginException(-1, '重定向次数过多: $url');
  }

  Map<String, dynamic> _handleRet(
    Response<dynamic> res, {
    bool verifyCode = true,
  }) {
    if (res.statusCode != 200) {
      throw MijiaLoginException(res.statusCode ?? -1, _bodyText(res));
    }
    final data = _parseServiceRet(res);
    final code = _asInt(data['code']);
    if (verifyCode && code != 0) {
      throw MijiaLoginException(code, '${data['desc'] ?? '未知错误'}');
    }
    return data;
  }

  Map<String, dynamic> _parseServiceRet(Response<dynamic> res) =>
      _asJsonMap(jsonDecode(_bodyText(res).replaceAll('&&&START&&&', '')));

  /// Merges `set-cookie` headers into [jar], the equivalent of reading
  /// `requests.Session.cookies.get_dict()`.
  void _mergeCookies(Response<dynamic> res, Map<String, String> jar) {
    final raw = res.headers['set-cookie'];
    if (raw == null) return;
    for (final header in raw) {
      for (final cookie in _splitSetCookieHeader(header)) {
        final pair = cookie.split(';').first;
        final eq = pair.indexOf('=');
        if (eq <= 0) continue;
        final name = pair.substring(0, eq).trim();
        if (name.isEmpty) continue;
        jar[name] = pair.substring(eq + 1).trim();
      }
    }
  }

  // ---------------------------------------------------------------------------
  // API methods
  // ---------------------------------------------------------------------------

  /// Checks for messages newer than [beginAt] (Unix seconds).
  ///
  /// Also serves as the cheap validity probe for the current token.
  Future<Map<String, dynamic>> checkNewMsg({
    int? beginAt,
    bool refreshToken = true,
  }) async {
    const uri = '/v2/message/v2/check_new_msg';
    final result = await request(
      uri,
      <String, dynamic>{'begin_at': beginAt ?? _nowSeconds - 3600},
      refreshToken: refreshToken,
    );
    return _asJsonMap(result);
  }

  /// Every home the account can see, including shared ones.
  Future<List<dynamic>> getHomesList() async {
    const uri = '/v2/homeroom/gethome_merged';
    final result = await request(uri, <String, dynamic>{
      'fg': true,
      'fetch_share': true,
      'fetch_share_dev': true,
      'fetch_cariot': true,
      'limit': 300,
      'app_ver': 7,
      'plat_form': 0,
    });
    return _asJsonMap(result)['homelist'] as List<dynamic>;
  }

  /// Devices in [homeId], or in every home when [homeId] is `null`.
  Future<List<dynamic>> getDevicesList({String? homeId}) async {
    if (homeId == null) {
      final homes = await getHomesList();
      final devices = <dynamic>[];
      for (final home in homes) {
        devices.addAll(await _getDevicesList('${_asJsonMap(home)['id']}'));
      }
      return devices;
    }
    return _getDevicesList(homeId);
  }

  /// Devices shared with this account. Not scoped to a home.
  Future<List<dynamic>> getSharedDevicesList() async {
    const uri = '/v2/home/device_list_page';
    final result = await request(uri, <String, dynamic>{
      'ssid': '<unknown ssid>',
      'bssid': '02:00:00:00:00:00',
      'getVirtualModel': true,
      'getHuamiDevices': 1,
      'get_split_device': true,
      'support_smart_home': true,
      'get_cariot_device': true,
      'get_third_device': true,
      'get_phone_device': true,
      'get_miwear_device': true,
    });
    final list = _asJsonMap(result)['list'] as List<dynamic>;
    final devices =
        list.where((item) => _asJsonMap(item)['owner'] == true).toList();
    for (final device in devices) {
      _asJsonMap(device)['home_id'] = 'shared';
    }
    return devices;
  }

  /// Manual scenes in [homeId], or in every home when [homeId] is `null`.
  Future<List<dynamic>> getScenesList({String? homeId}) async {
    if (homeId == null) {
      final homes = await getHomesList();
      final scenes = <dynamic>[];
      for (final home in homes) {
        scenes.addAll(await _getScenesList('${_asJsonMap(home)['id']}'));
      }
      return scenes;
    }
    return _getScenesList(homeId);
  }

  /// Triggers the manual scene [sceneId] belonging to [homeId].
  Future<bool> runScene({
    required String sceneId,
    required String homeId,
  }) async {
    const uri = '/appgateway/miot/appsceneservice/AppSceneService/NewRunScene';
    final result = await request(uri, <String, dynamic>{
      'scene_id': sceneId,
      'scene_type': 2,
      'phone_id': 'null',
      'home_id': homeId,
      'owner_uid': await _getHomeOwner(homeId),
    });
    return _isTruthy(result);
  }

  /// Consumables (filters, batteries, …) in [homeId], or in every home.
  Future<List<dynamic>> getConsumableItems({String? homeId}) async {
    if (homeId == null) {
      final homes = await getHomesList();
      final items = <dynamic>[];
      for (final home in homes) {
        items.addAll(await _getConsumableItems('${_asJsonMap(home)['id']}'));
      }
      return items;
    }
    return _getConsumableItems(homeId);
  }

  /// Reads device properties.
  ///
  /// [data] is either one `{did, siid, piid}` map or a list of them; the return
  /// shape follows the input — a map in, a map out.
  Future<dynamic> getDevicesProp(dynamic data) async {
    const uri = '/miotspec/prop/get';
    final params = data is Map ? <dynamic>[data] : data as List<dynamic>;
    final retData = await request(uri, <String, dynamic>{
      'params': params,
      'datasource': 1,
    });
    if (data is Map && retData is List && retData.length == 1) {
      return retData.first;
    }
    return retData;
  }

  /// Writes device properties.
  ///
  /// Takes the same shapes as [getDevicesProp]; each entry also carries a
  /// `value`. Every result gains a `message` describing the outcome.
  Future<dynamic> setDevicesProp(dynamic data) async {
    const uri = '/miotspec/prop/set';
    final params = data is Map ? <dynamic>[data] : data as List<dynamic>;
    final retData =
        await request(uri, <String, dynamic>{'params': params}) as List;
    _annotateResults(retData);
    if (data is Map && retData.length == 1) {
      return retData.first;
    }
    return retData;
  }

  /// Invokes device actions.
  ///
  /// Takes the same shapes as [getDevicesProp], with `aiid` in place of `piid`
  /// and an optional `value` list. Python issues one request per entry, and so
  /// does this port.
  Future<dynamic> runAction(dynamic data) async {
    const uri = '/miotspec/action';
    final params = data is Map ? <dynamic>[data] : data as List<dynamic>;
    final retData = <dynamic>[];
    for (final param in params) {
      retData.add(await request(uri, <String, dynamic>{'params': param}));
    }
    _annotateResults(retData);
    if (data is Map && retData.length == 1) {
      return retData.first;
    }
    return retData;
  }

  /// Reads statistics such as power consumption.
  ///
  /// [data] is `{did, key, data_type, limit, time_start, time_end}` or a list
  /// of such maps. `key` is usually `siid.piid` (e.g. `"7.1"`) and `data_type`
  /// one of `stat_hour_v3`, `stat_day_v3`, `stat_week_v3`, `stat_month_v3`;
  /// older devices drop the `_v3` suffix. Each returned `value` is typically a
  /// JSON array string such as `"[48.476]"`.
  Future<dynamic> getStatistics(dynamic data) async {
    const uri = '/v2/user/statistics';
    final params = data is Map ? <dynamic>[data] : data as List<dynamic>;
    final retData = <dynamic>[];
    for (final param in params) {
      retData.add(await request(uri, _asJsonMap(param)));
    }
    if (data is Map && retData.length == 1) {
      return retData.first;
    }
    return retData;
  }

  // ---------------------------------------------------------------------------
  // Composite call helpers
  // ---------------------------------------------------------------------------

  Future<List<dynamic>> _getDevicesList(String homeId) async {
    const uri = '/home/home_device_list';
    final owner = await _getHomeOwner(homeId);
    final devices = <dynamic>[];
    var startDid = '';
    var hasMore = true;

    while (hasMore) {
      final ret = _asJsonMap(await request(uri, <String, dynamic>{
        'home_owner': owner,
        'home_id': int.parse(homeId),
        'limit': 200,
        'start_did': startDid,
        'get_split_device': true,
        'support_smart_home': true,
        'get_cariot_device': true,
        'get_third_device': true,
      }));
      final deviceInfo = ret['device_info'];
      if (deviceInfo is List && deviceInfo.isNotEmpty) {
        devices.addAll(deviceInfo);
        startDid = '${ret['max_did'] ?? ''}';
        hasMore = ret['has_more'] == true && startDid.isNotEmpty;
      } else {
        hasMore = false;
      }
    }
    return _addHomeId(devices, homeId);
  }

  Future<List<dynamic>> _getScenesList(String homeId) async {
    const uri =
        '/appgateway/miot/appsceneservice/AppSceneService/GetSimpleSceneList';
    final ret = _asJsonMap(await request(uri, <String, dynamic>{
      'app_version': 12,
      'get_type': 2,
      'home_id': homeId,
      'owner_uid': await _getHomeOwner(homeId),
    }));
    final scenes = ret['manual_scene_info_list'];
    return scenes is List ? _addHomeId(scenes, homeId) : <dynamic>[];
  }

  Future<List<dynamic>> _getConsumableItems(String homeId) async {
    const uri = '/v2/home/standard_consumable_items';
    final ret = _asJsonMap(await request(uri, <String, dynamic>{
      'home_id': int.parse(homeId),
      'owner_id': await _getHomeOwner(homeId),
      'filter_ignore': true,
    }));
    try {
      final items = (_asJsonMap((ret['items'] as List).first)['consumes_data']
          as List<dynamic>);
      for (final item in items) {
        final details = _asJsonMap(item)['details'];
        if (details is List && details.length == 1) {
          _asJsonMap(item)['details'] = details.first;
        }
      }
      return _addHomeId(items, homeId);
    } on TypeError {
      // `items`/`consumes_data` were absent or the wrong shape, i.e. the
      // Python `KeyError` path.
      return <dynamic>[];
    } on StateError {
      // `items` was present but empty, i.e. the Python `IndexError` path.
      return <dynamic>[];
    }
  }

  /// `uid` of the owner of [homeId].
  Future<int> _getHomeOwner(String homeId) async {
    final homes = await getHomesList();
    for (final home in homes) {
      final map = _asJsonMap(home);
      if ('${map['id']}' == homeId) {
        return _asInt(map['uid']);
      }
    }
    throw MijiaApiException(-1, '未找到 home_id=$homeId 的家庭信息');
  }

  List<dynamic> _addHomeId(List<dynamic> items, String homeId) {
    for (final item in items) {
      _asJsonMap(item)['home_id'] = homeId;
    }
    return items;
  }

  /// Adds the `message` field Python attaches to prop/action results.
  void _annotateResults(List<dynamic> results) {
    for (final ret in results) {
      final code = _asInt(_asJsonMap(ret)['code']);
      _asJsonMap(ret)['message'] =
          code == 0 || code == 1 ? '成功' : miotErrorMessage(code);
    }
  }

  // ---------------------------------------------------------------------------
  // Small utilities
  // ---------------------------------------------------------------------------

  static int get _nowSeconds => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  String _randomString(String alphabet, int length) {
    final rnd = _random ?? Random.secure();
    return String.fromCharCodes(
      List<int>.generate(
        length,
        (_) => alphabet.codeUnitAt(rnd.nextInt(alphabet.length)),
        growable: false,
      ),
    );
  }

  static String _resolveTimeZoneId() {
    final fromEnvironment = Platform.environment['TZ']?.trim();
    if (fromEnvironment != null && _isHeaderSafe(fromEnvironment)) {
      return fromEnvironment;
    }

    final name = DateTime.now().timeZoneName;
    if (_isHeaderSafe(name)) return name;

    final offset = DateTime.now().timeZoneOffset;
    // Only whole-hour offsets have an `Etc/GMT±N` spelling.
    if (offset.inMinutes % 60 != 0) return 'UTC';
    final hours = offset.inHours;
    if (hours == 0) return 'Etc/GMT';
    // `Etc/GMT` signs are inverted relative to the usual convention.
    return hours > 0 ? 'Etc/GMT-$hours' : 'Etc/GMT+${-hours}';
  }

  /// Whether [value] is non-empty printable ASCII, and so legal in a header.
  static bool _isHeaderSafe(String value) =>
      value.isNotEmpty &&
      value.codeUnits.every((unit) => unit > 0x20 && unit < 0x7f);

  /// Whether the local zone ever shifts clocks, i.e. `time.daylight`.
  bool get _zoneHasDaylightSaving =>
      DateTime(2024, 1, 15).timeZoneOffset !=
      DateTime(2024, 7, 15).timeZoneOffset;

  /// Current DST shift in milliseconds, i.e. `tm_isdst * 3600 * 1000`.
  ///
  /// DST always moves clocks forward, so the larger of the two observed offsets
  /// is the daylight one.
  int get _currentDstOffsetMs {
    final jan = DateTime(2024, 1, 15).timeZoneOffset;
    final jul = DateTime(2024, 7, 15).timeZoneOffset;
    if (jan == jul) return 0;
    final daylight = jan > jul ? jan : jul;
    final standard = jan > jul ? jul : jan;
    return DateTime.now().timeZoneOffset == daylight
        ? (daylight - standard).inMilliseconds
        : 0;
  }

  /// Normalises the locale to `xx_YY`, falling back to `zh_CN`.
  ///
  /// Mirrors the Python guard that keeps the locale in a shape the API and the
  /// session cookie can both carry.
  static String _normalizeLocale(String? locale) {
    final value = (locale ?? Platform.localeName).replaceAll('-', '_');
    return RegExp(r'^[A-Za-z]{2,3}_[A-Za-z]{2,4}$').hasMatch(value)
        ? value
        : 'zh_CN';
  }

  static String _bodyText(Response<dynamic> res) {
    final data = res.data;
    if (data == null) return '';
    if (data is String) return data;
    if (data is List<int>) return utf8.decode(data, allowMalformed: true);
    return '$data';
  }

  /// Views [decoded] as a `Map<String, dynamic>`.
  ///
  /// Returns the same instance when the type already matches, because callers
  /// annotate the decoded JSON in place (adding `home_id`, `message`, …) and
  /// those writes have to reach the object the caller holds.
  static Map<String, dynamic> _asJsonMap(dynamic decoded) {
    if (decoded is Map<String, dynamic>) return decoded;
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
    throw MijiaApiException(-1, '响应不是 JSON 对象: $decoded');
  }

  /// Tolerant `int` conversion, standing in for Python's `int(value)`.
  static int _asInt(dynamic value) {
    if (value == null) return 0;
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse('$value') ?? 0;
  }

  /// Python truthiness, used where the original returns a raw API value.
  static bool _isTruthy(dynamic value) {
    if (value == null) return false;
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) return value.isNotEmpty;
    if (value is Iterable) return value.isNotEmpty;
    if (value is Map) {
      final code = value['code'];
      return code is num ? code == 0 : value.isNotEmpty;
    }
    return true;
  }

  /// Dart's `Uri` drops empty values, so encode the way `parse.urlencode` does.
  static String _urlEncode(Map<String, dynamic> params) => params.entries
      .map((e) => '${Uri.encodeQueryComponent(e.key)}='
          '${Uri.encodeQueryComponent('${e.value}')}')
      .join('&');

  /// `parse.parse_qs(parse.urlparse(location).query)` collapsed to first values.
  static Map<String, dynamic> _parseLocationQuery(String location) {
    final uri = Uri.tryParse(location);
    if (uri == null) return <String, dynamic>{};
    final result = <String, dynamic>{};
    uri.queryParametersAll.forEach((key, values) {
      if (values.isNotEmpty) result[key] = values.first;
    });
    return result;
  }

  /// Splits a `set-cookie` value that a transport may have comma-joined.
  ///
  /// A comma only separates cookies when what follows looks like `name=value`,
  /// so `Expires=Wed, 21 Oct 2026 07:28:00 GMT` is left intact.
  static List<String> _splitSetCookieHeader(String header) {
    final attribute = RegExp(r'^\s*[!#$%&*+\-.^_`|~0-9A-Za-z]+\s*=');
    final parts = <String>[];
    var start = 0;
    for (var i = 0; i < header.length; i++) {
      if (header[i] != ',') continue;
      if (attribute.hasMatch(header.substring(i + 1))) {
        parts.add(header.substring(start, i));
        start = i + 1;
      }
    }
    parts.add(header.substring(start));
    return parts.where((part) => part.trim().isNotEmpty).toList();
  }
}
