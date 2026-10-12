/// Navigation-only URLs; never serialize authentication, searches or mail content.
class MailRoute {
  final String? messageId;
  final String account, folder, filter, settings;
  const MailRoute({
    this.messageId,
    this.account = '',
    this.folder = 'INBOX',
    this.filter = 'all',
    this.settings = '',
  });
  static final _id = RegExp(r'^[A-Za-z0-9_-]{1,160}$');
  static bool validId(String value) => _id.hasMatch(value);
  static const _filters = {'all', 'unread', 'starred'};
  static MailRoute parse(String location) {
    try {
      if (!location.startsWith('/') ||
          location.startsWith('//') ||
          location.length > 1500) {
        return const MailRoute();
      }
      final uri = Uri.parse(location);
      if (uri.hasScheme || uri.hasAuthority || uri.hasFragment) {
        return const MailRoute();
      }
      final parts = uri.pathSegments;
      String? message;
      var settings = '';
      if (parts.length == 2 && parts[0] == 'mail' && validId(parts[1])) {
        message = parts[1];
      } else if (parts.firstOrNull == 'settings' && parts.length <= 2) {
        settings = parts.length == 1 ? 'accounts' : parts[1];
        if (!{
          'accounts',
          'add',
          'oauth',
          'devices',
          'passkeys',
        }.contains(settings)) {
          return const MailRoute();
        }
      } else if (uri.path != '/' && uri.path != '/mail') {
        return const MailRoute();
      }
      final account = uri.queryParameters['account'] ?? '';
      final folder = uri.queryParameters['folder'] ?? 'INBOX';
      final filter = uri.queryParameters['filter'] ?? 'all';
      if ((account.isNotEmpty && !validId(account)) ||
          folder.isEmpty ||
          folder.length > 256 ||
          RegExp(r'[\x00-\x1f\x7f]').hasMatch(folder) ||
          !_filters.contains(filter)) {
        return const MailRoute();
      }
      return MailRoute(
        messageId: message,
        account: account,
        folder: folder,
        filter: filter,
        settings: settings,
      );
    } on FormatException {
      return const MailRoute();
    }
  }

  String get location {
    final query = <String, String>{
      if (account.isNotEmpty && validId(account)) 'account': account,
      if (folder != 'INBOX') 'folder': folder,
      if (filter != 'all' && _filters.contains(filter)) 'filter': filter,
    };
    return Uri(
      path: settings.isNotEmpty
          ? '/settings/$settings'
          : messageId != null && validId(messageId!)
          ? '/mail/$messageId'
          : '/mail',
      queryParameters: query.isEmpty ? null : query,
    ).toString();
  }
}
