import 'dart:convert';
import 'package:dio/dio.dart';
import 'result.dart';
import 'search_query.dart';
import 'searchable.dart';
import 'settings/_exports.dart';
import 'tasks_results.dart';
import 'package:collection/collection.dart';
import 'client.dart';
import 'exception.dart';
import 'filter_builder/filter_builder_base.dart';
import 'http_request.dart';
import 'index.dart';
import 'matching_strategy_enum.dart';
import 'query_parameters/documents_query.dart';
import 'query_parameters/tasks_query.dart';
import 'stats.dart' show IndexStats;
import 'task.dart';

const _ndjsonContentType = 'application/x-ndjson';
const _csvContentType = 'text/csv';

class MeiliSearchIndexImpl implements MeiliSearchIndex {
  MeiliSearchIndexImpl(
    this.client,
    this.uid, {
    this.primaryKey,
    DateTime? createdAt,
    DateTime? updatedAt,
  })  : _createdAt = createdAt,
        _updatedAt = updatedAt;

  final MeiliSearchClient client;

  @override
  final String uid;

  @override
  String? primaryKey;

  DateTime? _createdAt;

  @override
  DateTime? get createdAt => _createdAt;

  DateTime? _updatedAt;

  @override
  DateTime? get updatedAt => _updatedAt;

  HttpRequest get http => client.http;

  factory MeiliSearchIndexImpl.fromMap(
    MeiliSearchClient client,
    Map<String, Object?> map,
  ) {
    final createdAtRaw = map['createdAt'];
    final primaryKeyRaw = map['primaryKey'];
    final updatedAtRaw = map['updatedAt'];

    return MeiliSearchIndexImpl(
      client,
      map['uid'] as String,
      primaryKey: primaryKeyRaw is String ? primaryKeyRaw : null,
      createdAt:
          createdAtRaw is String ? DateTime.tryParse(createdAtRaw) : null,
      updatedAt:
          updatedAtRaw is String ? DateTime.tryParse(updatedAtRaw) : null,
    );
  }

  //
  // Index endpoints
  //

  @override
  Future<Task> update({String? primaryKey}) async {
    final data = <String, Object?>{
      if (primaryKey != null) 'primaryKey': primaryKey,
    };

    return await _getTask(http.patchMethod('/indexes/$uid', data: data));
  }

  @override
  Future<Task> delete() async {
    return await _getTask(http.deleteMethod('/indexes/$uid'));
  }

  @override
  Future<MeiliSearchIndex> fetchInfo() async {
    final index = await client.getIndex(uid);
    primaryKey = index.primaryKey;
    _createdAt = index.createdAt;
    _updatedAt = index.updatedAt;
    return index;
  }

  @override
  Future<String?> fetchPrimaryKey() async {
    final index = await fetchInfo();
    return index.primaryKey;
  }

  //
  // Search endpoints
  //

  @override
  Future<Searcheable> search(
    String? query, {
    int? offset,
    int? limit,
    int? page,
    int? hitsPerPage,
    Object? filter,
    MeiliOperatorExpressionBase? filterExpression,
    List<String>? sort,
    List<String>? facets,
    List<String>? attributesToRetrieve,
    List<String>? attributesToCrop,
    int? cropLength,
    List<String>? attributesToHighlight,
    bool? showMatchesPosition,
    String? cropMarker,
    String? highlightPreTag,
    String? highlightPostTag,
    MatchingStrategy? matchingStrategy,
  }) async {
    final data = SearchQuery(
      indexUid: uid,
      query: query,
      offset: offset,
      limit: limit,
      page: page,
      hitsPerPage: hitsPerPage,
      filter: filter,
      filterExpression: filterExpression,
      sort: sort,
      facets: facets,
      attributesToRetrieve: attributesToRetrieve,
      attributesToCrop: attributesToCrop,
      cropLength: cropLength,
      attributesToHighlight: attributesToHighlight,
      showMatchesPosition: showMatchesPosition,
      cropMarker: cropMarker,
      highlightPreTag: highlightPreTag,
      highlightPostTag: highlightPostTag,
      matchingStrategy: matchingStrategy,
    ).toMap();

    final response = await http.postMethod<Map<String, Object?>>(
        '/indexes/$uid/search',
        data: data..remove('indexUid'));

    return Searcheable.createSearchResult(response.data!, indexUid: uid);
  }

  //
  // Document endpoints
  //

  Future<Task> _getTask(Future<Response<Map<String, Object?>>> future) async {
    final response = await future;
    return Task.fromMap(response.data!);
  }

  @override
  Future<Task> addDocuments(
    documents, {
    String? primaryKey,
  }) {
    return _getTask(http.postMethod(
      '/indexes/$uid/documents',
      data: documents,
      queryParameters: {
        if (primaryKey != null) 'primaryKey': primaryKey,
      },
    ));
  }

  @override
  Future<Task> addDocumentsJson(String documents, {String? primaryKey}) {
    final decoded = jsonDecode(documents);

    if (decoded is List<Object?>) {
      final casted = decoded.whereType<Map<String, Object?>>().toList();

      return addDocuments(casted, primaryKey: primaryKey);
    }

    throw MeiliSearchApiException(
      "Provided json must be an array of documents, consider using addDocumentsNdjson if this isn't the case",
    );
  }

  @override
  Future<Task> addDocumentsCsv(
    String documents, {
    String? primaryKey,
  }) {
    return _getTask(http.postMethod(
      '/indexes/$uid/documents',
      data: documents,
      queryParameters: {
        if (primaryKey != null) 'primaryKey': primaryKey,
      },
      contentType: _csvContentType,
    ));
  }

  @override
  Future<Task> addDocumentsNdjson(String documents, {String? primaryKey}) {
    return _getTask(http.postMethod(
      '/indexes/$uid/documents',
      data: documents,
      queryParameters: {
        if (primaryKey != null) 'primaryKey': primaryKey,
      },
      contentType: _ndjsonContentType,
    ));
  }

  @override
  Future<List<Task>> addDocumentsInBatches(
    List<Map<String, Object?>> documents, {
    int batchSize = 1000,
    String? primaryKey,
  }) =>
      Future.wait(
        documents
            .slices(batchSize)
            .map((slice) => addDocuments(slice, primaryKey: primaryKey)),
      );

  @override
  Future<List<Task>> addDocumentsCsvInBatches(
    String documents, {
    String? primaryKey,
    int batchSize = 1000,
  }) {
    final ls = LineSplitter();
    final split = ls.convert(documents);
    //header is shared for all slices
    final header = split.first;
    return Future.wait(
      split.skip(1).slices(batchSize).map(
            (slice) => addDocumentsCsv(
              [header, ...slice].join('\n'),
              primaryKey: primaryKey,
            ),
          ),
    );
  }

  @override
  Future<List<Task>> addDocumentsNdjsonInBatches(
    String documents, {
    String? primaryKey,
    int batchSize = 1000,
  }) {
    final ls = LineSplitter();
    final split = ls.convert(documents);

    return Future.wait(
      split.slices(batchSize).map(
            (slice) => addDocumentsNdjson(
              slice.join('\n'),
              primaryKey: primaryKey,
            ),
          ),
    );
  }

  @override
  Future<Task> updateDocuments(
    documents, {
    String? primaryKey,
  }) async {
    return await _getTask(http.putMethod(
      '/indexes/$uid/documents',
      data: documents,
      queryParameters: {
        if (primaryKey != null) 'primaryKey': primaryKey,
      },
    ));
  }

  @override
  Future<Task> updateDocumentsJson(
    String documents, {
    String? primaryKey,
  }) {
    final decoded = jsonDecode(documents);

    if (decoded is List<Object?>) {
      final casted = decoded.whereType<Map<String, Object?>>().toList();

      return updateDocuments(casted, primaryKey: primaryKey);
    }

    throw MeiliSearchApiException(
      "Provided json must be an array of documents, consider using updateDocumentsNdjson if this isn't the case",
    );
  }

  @override
  Future<Task> updateDocumentsCsv(String documents, {String? primaryKey}) {
    return _getTask(http.putMethod(
      '/indexes/$uid/documents',
      data: documents,
      queryParameters: {
        if (primaryKey != null) 'primaryKey': primaryKey,
      },
      contentType: _csvContentType,
    ));
  }

  @override
  Future<Task> updateDocumentsNdjson(String documents, {String? primaryKey}) {
    return _getTask(http.putMethod(
      '/indexes/$uid/documents',
      data: documents,
      queryParameters: {
        if (primaryKey != null) 'primaryKey': primaryKey,
      },
      contentType: _ndjsonContentType,
    ));
  }

  @override
  Future<List<Task>> updateDocumentsInBatches(
    List<Map<String, Object?>> documents, {
    int batchSize = 1000,
    String? primaryKey,
  }) =>
      Future.wait(
        documents
            .slices(batchSize)
            .map((slice) => updateDocuments(slice, primaryKey: primaryKey)),
      );

  @override
  Future<List<Task>> updateDocumentsCsvInBatches(
    String documents, {
    String? primaryKey,
    int batchSize = 1000,
  }) {
    final ls = LineSplitter();
    final split = ls.convert(documents);
    //header is shared for all slices
    final header = split.first;

    return Future.wait(
      split.skip(1).slices(batchSize).map(
            (slice) => updateDocumentsCsv(
              [header, ...slice].join('\n'),
              primaryKey: primaryKey,
            ),
          ),
    );
  }

  @override
  Future<List<Task>> updateDocumentsNdjsonInBatches(
    String documents, {
    String? primaryKey,
    int batchSize = 1000,
  }) {
    final ls = LineSplitter();
    final split = ls.convert(documents);

    return Future.wait(
      split.slices(batchSize).map(
            (slice) => updateDocumentsNdjson(
              slice.join('\n'),
              primaryKey: primaryKey,
            ),
          ),
    );
  }

  @override
  Future<Task> deleteAllDocuments() async {
    return await _getTask(http.deleteMethod('/indexes/$uid/documents'));
  }

  @override
  Future<Task> deleteDocument(Object? id) async {
    return await _getTask(http.deleteMethod('/indexes/$uid/documents/$id'));
  }

  @override
  Future<Task> deleteDocuments(List<Object> ids) async {
    return await _getTask(
      http.postMethod(
        '/indexes/$uid/documents/delete-batch',
        data: ids,
      ),
    );
  }

  @override
  Future<Map<String, Object?>?> getDocument(Object id,
      {List<String> fields = const []}) async {
    final params = DocumentsQuery(fields: fields);
    final response = await http.getMethod<Map<String, Object?>>(
        '/indexes/$uid/documents/$id',
        queryParameters: params.toQuery());

    return response.data;
  }

  @override
  Future<Result<Map<String, Object?>>> getDocuments(
      {DocumentsQuery? params}) async {
    final response = await http.getMethod<Map<String, Object?>>(
        '/indexes/$uid/documents',
        queryParameters: params?.toQuery());

    return Result.fromMap(response.data!);
  }

  //
  // Settings endpoints
  //

  @override
  Future<IndexSettings> getSettings() async {
    final response =
        await http.getMethod<Map<String, Object?>>('/indexes/$uid/settings');

    return IndexSettings.fromMap(response.data!);
  }

  @override
  Future<Task> resetSettings() async {
    return await _getTask(http.deleteMethod('/indexes/$uid/settings'));
  }

  @override
  Future<Task> updateSettings(IndexSettings settings) async {
    return await _getTask(http.patchMethod(
      '/indexes/$uid/settings',
      data: settings.toMap(),
    ));
  }

  @override
  Future<List<String>> getFilterableAttributes() async {
    final response = await http.getMethod<List<Object?>>(
        '/indexes/$uid/settings/filterable-attributes');

    return response.data!.cast<String>();
  }

  @override
  Future<Task> resetFilterableAttributes() async {
    return await _getTask(
        http.deleteMethod('/indexes/$uid/settings/filterable-attributes'));
  }

  @override
  Future<Task> updateFilterableAttributes(
      List<String> filterableAttributes) async {
    return await _getTask(http.putMethod(
        '/indexes/$uid/settings/filterable-attributes',
        data: filterableAttributes));
  }

  @override
  Future<List<String>> getDisplayedAttributes() async {
    final response = await http.getMethod<List<Object?>>(
        '/indexes/$uid/settings/displayed-attributes');

    return response.data!.cast<String>();
  }

  @override
  Future<Task> resetDisplayedAttributes() async {
    return await _getTask(
        http.deleteMethod('/indexes/$uid/settings/displayed-attributes'));
  }

  @override
  Future<Task> updateDisplayedAttributes(
      List<String> displayedAttributes) async {
    return await _getTask(http.putMethod(
        '/indexes/$uid/settings/displayed-attributes',
        data: displayedAttributes));
  }

  @override
  Future<String?> getDistinctAttribute() async {
    final response = await http
        .getMethod<String?>('/indexes/$uid/settings/distinct-attribute');

    return response.data;
  }

  @override
  Future<Task> resetDistinctAttribute() async {
    return await _getTask(
        http.deleteMethod('/indexes/$uid/settings/distinct-attribute'));
  }

  @override
  Future<Task> updateDistinctAttribute(String distinctAttribute) async {
    return await _getTask(http.putMethod(
        '/indexes/$uid/settings/distinct-attribute',
        data: '"$distinctAttribute"'));
  }

  @override
  Future<List<String>> getRankingRules() async {
    final response = await http
        .getMethod<List<Object?>>('/indexes/$uid/settings/ranking-rules');

    return response.data!.cast<String>();
  }

  @override
  Future<Task> resetRankingRules() async {
    return await _getTask(
        http.deleteMethod('/indexes/$uid/settings/ranking-rules'));
  }

  @override
  Future<Task> updateRankingRules(List<String> rankingRules) async {
    return await _getTask(http.putMethod('/indexes/$uid/settings/ranking-rules',
        data: rankingRules));
  }

  @override
  Future<List<String>> getStopWords() async {
    final response = await http
        .getMethod<List<Object?>>('/indexes/$uid/settings/stop-words');

    return response.data!.cast<String>();
  }

  @override
  Future<Task> resetStopWords() async {
    return await _getTask(
        http.deleteMethod('/indexes/$uid/settings/stop-words'));
  }

  @override
  Future<List<String>> getSearchableAttributes() async {
    final response = await http.getMethod<List<Object?>>(
        '/indexes/$uid/settings/searchable-attributes');

    return response.data!.cast<String>();
  }

  @override
  Future<Task> resetSearchableAttributes() async {
    return await _getTask(
        http.deleteMethod('/indexes/$uid/settings/searchable-attributes'));
  }

  @override
  Future<Task> updateSearchableAttributes(
      List<String> searchableAttributes) async {
    return await _getTask(http.putMethod(
        '/indexes/$uid/settings/searchable-attributes',
        data: searchableAttributes));
  }

  @override
  Future<Task> updateStopWords(List<String> stopWords) async {
    return await _getTask(
        http.putMethod('/indexes/$uid/settings/stop-words', data: stopWords));
  }

  @override
  Future<Map<String, List<String>>> getSynonyms() async {
    final response = await http
        .getMethod<Map<String, Object?>>('/indexes/$uid/settings/synonyms');

    return response.data!
        .map((key, value) => MapEntry(key, (value as List).cast<String>()));
  }

  @override
  Future<Task> resetSynonyms() async {
    return await _getTask(http.deleteMethod('/indexes/$uid/settings/synonyms'));
  }

  @override
  Future<Task> updateSynonyms(Map<String, List<String>> synonyms) async {
    return await _getTask(
        http.putMethod('/indexes/$uid/settings/synonyms', data: synonyms));
  }

  @override
  Future<List<String>> getSortableAttributes() async {
    final response = await http
        .getMethod<List<Object?>>('/indexes/$uid/settings/sortable-attributes');

    return response.data!.cast<String>();
  }

  @override
  Future<Task> resetSortableAttributes() async {
    return await _getTask(
        http.deleteMethod('/indexes/$uid/settings/sortable-attributes'));
  }

  @override
  Future<Task> updateSortableAttributes(List<String> sortableAttributes) async {
    return _getTask(
      http.putMethod(
        '/indexes/$uid/settings/sortable-attributes',
        data: sortableAttributes,
      ),
    );
  }

  @override
  Future<TypoTolerance> getTypoTolerance() async {
    final response = await http.getMethod<Map<String, Object?>>(
      '/indexes/$uid/settings/typo-tolerance',
    );

    return TypoTolerance.fromMap(response.data!);
  }

  @override
  Future<Task> resetTypoTolerance() async {
    return await _getTask(
      http.deleteMethod('/indexes/$uid/settings/typo-tolerance'),
    );
  }

  @override
  Future<Task> updateTypoTolerance(TypoTolerance typoTolerance) async {
    return await _getTask(
      http.patchMethod(
        '/indexes/$uid/settings/typo-tolerance',
        data: typoTolerance.toMap(),
      ),
    );
  }

  @override
  Future<Pagination> getPagination() async {
    final response = await http.getMethod<Map<String, Object?>>(
      '/indexes/$uid/settings/pagination',
    );

    return Pagination.fromMap(response.data!);
  }

  @override
  Future<Task> resetPagination() async {
    return await _getTask(
      http.deleteMethod('/indexes/$uid/settings/pagination'),
    );
  }

  @override
  Future<Task> updatePagination(Pagination pagination) async {
    return await _getTask(
      http.patchMethod(
        '/indexes/$uid/settings/pagination',
        data: pagination.toMap(),
      ),
    );
  }

  @override
  Future<Faceting> getFaceting() async {
    final response = await http.getMethod<Map<String, Object?>>(
      '/indexes/$uid/settings/faceting',
    );

    return Faceting.fromMap(response.data!);
  }

  @override
  Future<Task> resetFaceting() async {
    return await _getTask(
      http.deleteMethod('/indexes/$uid/settings/faceting'),
    );
  }

  @override
  Future<Task> updateFaceting(Faceting faceting) async {
    return await _getTask(
      http.patchMethod(
        '/indexes/$uid/settings/faceting',
        data: faceting.toMap(),
      ),
    );
  }

  ///
  /// Stats endponts
  ///

  @override
  Future<IndexStats> getStats() async {
    final response =
        await http.getMethod<Map<String, Object?>>('/indexes/$uid/stats');

    return IndexStats.fromMap(response.data!);
  }

  ///
  /// Tasks endpoints
  ///

  @override
  Future<TasksResults> getTasks({TasksQuery? params}) async {
    if (params == null) {
      params = TasksQuery(indexUids: [uid]);
    } else {
      if (!params.indexUids.contains(uid)) {
        params = params.copyWith(indexUids: [...params.indexUids, uid]);
      }
    }

    return await client.getTasks(params: params);
  }

  @override
  Future<Task> getTask(int uid) async {
    return await client.getTask(uid);
  }
}
