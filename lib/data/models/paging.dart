import 'package:equatable/equatable.dart';

import 'json_utils.dart';

/// Spotify's offset-based page wrapper.
///
/// Kept generic so `Paging<Track>` and `Paging<Album>` share one pagination
/// implementation in the repositories and one "load more" trigger in the UI.
class Paging<T> extends Equatable {
  const Paging({
    required this.items,
    required this.total,
    required this.limit,
    required this.offset,
    this.next,
    this.previous,
  });

  final List<T> items;
  final int total;
  final int limit;
  final int offset;
  final String? next;
  final String? previous;

  static Paging<T> empty<T>() =>
      Paging<T>(items: const [], total: 0, limit: 0, offset: 0);

  factory Paging.fromJson(
    Map<String, dynamic> json,
    T Function(Map<String, dynamic>) parse,
  ) => Paging<T>(
    items: Json.list(json, 'items', parse),
    total: Json.intVal(json, 'total'),
    limit: Json.intVal(json, 'limit'),
    offset: Json.intVal(json, 'offset'),
    next: Json.strOrNull(json, 'next'),
    previous: Json.strOrNull(json, 'previous'),
  );

  Map<String, dynamic> toJson(Map<String, dynamic> Function(T) encode) =>
      <String, dynamic>{
        'items': items.map(encode).toList(),
        'total': total,
        'limit': limit,
        'offset': offset,
        if (next != null) 'next': next,
        if (previous != null) 'previous': previous,
      };

  bool get hasMore => next != null;
  bool get isEmpty => items.isEmpty;
  bool get isNotEmpty => items.isNotEmpty;
  int get nextOffset => offset + limit;

  Paging<R> map<R>(R Function(T) transform) => Paging<R>(
    items: items.map(transform).toList(growable: false),
    total: total,
    limit: limit,
    offset: offset,
    next: next,
    previous: previous,
  );

  /// Appends the next page, keeping this page's offset/total metadata current.
  /// Used by the infinite-scroll controllers.
  Paging<T> append(Paging<T> nextPage) => Paging<T>(
    items: [...items, ...nextPage.items],
    total: nextPage.total,
    limit: nextPage.limit,
    offset: nextPage.offset,
    next: nextPage.next,
    previous: nextPage.previous,
  );

  @override
  List<Object?> get props => [items, total, limit, offset, next, previous];
}

/// Cursor-paged wrapper, used by `/me/player/recently-played` and
/// `/me/following`, which cannot be offset-paged.
class CursorPaging<T> extends Equatable {
  const CursorPaging({
    required this.items,
    required this.limit,
    this.total,
    this.next,
    this.cursorAfter,
    this.cursorBefore,
  });

  final List<T> items;
  final int limit;
  final int? total;
  final String? next;
  final String? cursorAfter;
  final String? cursorBefore;

  static CursorPaging<T> empty<T>() =>
      CursorPaging<T>(items: const [], limit: 0);

  factory CursorPaging.fromJson(
    Map<String, dynamic> json,
    T Function(Map<String, dynamic>) parse,
  ) {
    final cursors = Json.obj(json, 'cursors');
    return CursorPaging<T>(
      items: Json.list(json, 'items', parse),
      limit: Json.intVal(json, 'limit'),
      total: Json.intOrNull(json, 'total'),
      next: Json.strOrNull(json, 'next'),
      cursorAfter: cursors == null ? null : Json.strOrNull(cursors, 'after'),
      cursorBefore: cursors == null ? null : Json.strOrNull(cursors, 'before'),
    );
  }

  bool get hasMore => next != null && cursorAfter != null;

  CursorPaging<T> append(CursorPaging<T> nextPage) => CursorPaging<T>(
    items: [...items, ...nextPage.items],
    limit: nextPage.limit,
    total: nextPage.total ?? total,
    next: nextPage.next,
    cursorAfter: nextPage.cursorAfter,
    cursorBefore: cursorBefore ?? nextPage.cursorBefore,
  );

  @override
  List<Object?> get props => [items, limit, total, next, cursorAfter, cursorBefore];
}
