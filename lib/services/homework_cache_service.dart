class HomeworkCacheService {
  static final HomeworkCacheService instance = HomeworkCacheService._();
  HomeworkCacheService._();

  final Map<String, Object?> _store = {};

  T? retrieve<T>(String key) {
    final v = _store[key];
    if (v is T) return v;
    return null;
  }

  void store(String key, Object? value) {
    _store[key] = value;
  }

  bool contains(String key) => _store.containsKey(key);

  void evict(String key) => _store.remove(key);

  void evictByPrefix(String prefix) {
    _store.removeWhere((k, _) => k.startsWith(prefix));
  }

  void clear() => _store.clear();
}
