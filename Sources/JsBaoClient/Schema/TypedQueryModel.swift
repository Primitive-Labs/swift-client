import Foundation

/// A generated model whose fields have typed tokens: `swift-bao-codegen`
/// conforms every model it writes, with one token per field (`id` included)
/// on `fields`. A vector field has no token.
///
/// The conformance gives the model labelled reads checked against its
/// fields, beside the `DocumentFilter` ones, which are unchanged:
///
/// ```swift
/// let f = TaskRecord.fields
/// let due = try TaskRecord.query(
///     where: .and([f.done.eq(false), f.dueDate.lt("2026-01-01")]),
///     sort: [.asc(f.dueDate), .desc(f.priority)]
/// )
/// let open = try TaskRecord.count(where: f.done.eq(false))
/// ```
///
/// A field the model does not have, an operand of the wrong type or an
/// operator the field's kind lacks fails to compile. Each call builds the
/// `DocumentFilter`, `sortOrder` and `AggregateOptions` the hand-written form
/// would, and reads through the same engine.
public protocol TypedQueryModel: PrimitiveModel, PrimitiveRowDecodable {
    /// The generated value holding one token per field: the model's nested
    /// `Fields` struct. Named with a leading underscore, which no field name
    /// may take, so a field named `Fields` cannot collide with it.
    associatedtype _FieldTokens: Sendable
    /// The model's field tokens.
    static var fields: _FieldTokens { get }
}

/// The token types, named through the model. Generated code declares a
/// token as `<Model>._StringFieldToken` rather than `ModelStringField<Model>`,
/// so a model of the app named like a token type (`ModelIdField`) cannot
/// shadow it. Named with a leading underscore, which no field name, and so
/// no nested type the generator writes, may take.
public extension TypedQueryModel {
    typealias _IdFieldToken = ModelIdField<Self>
    typealias _StringFieldToken = ModelStringField<Self>
    typealias _NumberFieldToken = ModelNumberField<Self>
    typealias _BooleanFieldToken = ModelBooleanField<Self>
    typealias _DateFieldToken = ModelDateField<Self>
    typealias _StringSetFieldToken = ModelStringSetField<Self>
    typealias _JSONFieldToken = ModelJSONField<Self>
    typealias _EnumFieldToken<Value: RawRepresentable & Sendable> = ModelEnumField<Self, Value>
        where Value.RawValue == String
}

public extension TypedQueryModel {
    // MARK: Reads

    /// Query across all open documents, as `query(_:options:)` does, with a
    /// typed filter and sort. `sort` reaches the engine as
    /// `options.sortOrder`, in the order given; an `options` that already
    /// sets `sort` or `sortOrder` beside a non-empty `sort` throws
    /// `.invalidArgument`. Pass `where: nil` to filter nothing.
    static func query(
        where filter: ModelFilter<Self>?, sort: [ModelSort<Self>] = [], options: QueryOptions? = nil
    ) throws -> [Self] {
        let options = try typedOptions(options, sort: sort)
        let rows = try JsBaoClient.requireDefault()
            .codegen.query(primitiveSchema, filter: filter?.documentFilter, options: options)
        return PrimitiveRowDecoder.decodeAll(rows, as: Self.self)
    }

    /// ``query(where:sort:options:)`` with query-time relationship includes
    /// attached under `related`.
    static func query(
        where filter: ModelFilter<Self>?, sort: [ModelSort<Self>] = [], options: QueryOptions? = nil, include: [Include]
    ) throws -> [Self] {
        let options = try typedOptions(options, sort: sort)
        let rows = try JsBaoClient.requireDefault()
            .codegen.query(primitiveSchema, filter: filter?.documentFilter, options: options, include: include)
        return PrimitiveRowDecoder.decodeAll(rows, as: Self.self)
    }

    /// Paginated ``query(where:sort:options:)``: round-trip `nextCursor`
    /// through `options.cursor` to page, as `queryPaged(_:options:)` does.
    static func queryPaged(
        where filter: ModelFilter<Self>?, sort: [ModelSort<Self>] = [], options: QueryOptions? = nil
    ) throws -> PagedQueryResult<Self> {
        let options = try typedOptions(options, sort: sort)
        let page = try JsBaoClient.requireDefault()
            .codegen.queryPaged(primitiveSchema, filter: filter?.documentFilter, options: options)
        return typedPage(page)
    }

    /// ``queryPaged(where:sort:options:)`` with query-time relationship includes.
    static func queryPaged(
        where filter: ModelFilter<Self>?, sort: [ModelSort<Self>] = [], options: QueryOptions? = nil, include: [Include]
    ) throws -> PagedQueryResult<Self> {
        let options = try typedOptions(options, sort: sort)
        let page = try JsBaoClient.requireDefault()
            .codegen.queryPaged(primitiveSchema, filter: filter?.documentFilter, options: options, include: include)
        return typedPage(page)
    }

    /// The first record ``query(where:sort:options:)`` answers, or `nil`.
    static func queryOne(
        where filter: ModelFilter<Self>?, sort: [ModelSort<Self>] = [], options: QueryOptions? = nil
    ) throws -> Self? {
        let options = try typedOptions(options, sort: sort)
        let row = try JsBaoClient.requireDefault()
            .codegen.queryOne(primitiveSchema, filter: filter?.documentFilter, options: options)
        return PrimitiveRowDecoder.decodeOne(row, as: Self.self)
    }

    /// ``queryOne(where:sort:options:)`` with query-time relationship includes.
    static func queryOne(
        where filter: ModelFilter<Self>?, sort: [ModelSort<Self>] = [], options: QueryOptions? = nil, include: [Include]
    ) throws -> Self? {
        let options = try typedOptions(options, sort: sort)
        let row = try JsBaoClient.requireDefault()
            .codegen.queryOne(primitiveSchema, filter: filter?.documentFilter, options: options, include: include)
        return PrimitiveRowDecoder.decodeOne(row, as: Self.self)
    }

    /// The number of records matching `filter` across all open documents, as
    /// `count(_:options:)` answers it.
    static func count(where filter: ModelFilter<Self>?, options: QueryOptions? = nil) throws -> Int {
        try JsBaoClient.requireDefault().codegen.count(primitiveSchema, filter: filter?.documentFilter, options: options)
    }

    // MARK: Aggregates

    /// Aggregate across all open documents, as `aggregate(_:)` does, with
    /// typed levels and operations. Each row answers the value of every key
    /// in `groupBy` and `operations` by that key:
    ///
    /// ```swift
    /// let category = f.category.group, n = TaskRecord.aggregateCount()
    /// let rows = try TaskRecord.aggregate(groupBy: [category], operations: [n])
    /// rows.first?[category]  // String?
    /// rows.first?[n]         // Int?
    /// ```
    static func aggregate(
        groupBy: [any AggregateGroupLevel<Self>],
        operations: [any AggregateOperationKey<Self>],
        where filter: ModelFilter<Self>? = nil,
        sort: AggregateSort? = nil,
        limit: Int? = nil,
        documents: [String]? = nil,
        db3: [String]? = nil
    ) throws -> [AggregateRow<Self>] {
        let options = AggregateOptions(
            groupBy: groupBy.map(\.level),
            operations: operations.map(\.operation),
            filter: filter?.documentFilter,
            sort: sort,
            limit: limit,
            documents: documents,
            db3: db3
        )
        return try JsBaoClient.requireDefault().codegen.aggregate(primitiveSchema, options: options)
            .map { AggregateRow(raw: $0) }
    }

    /// The `count` operation of an aggregate on this model, under
    /// `outputField` or `count`.
    static func aggregateCount(as outputField: String? = nil) -> AggregateResultKey<Self, Int> {
        AggregateResultKey<Self, Int>.count(as: outputField)
    }

    // MARK: Helpers

    /// `options` with a typed `sort` as its `sortOrder`. Refuses an
    /// `options` that sorts already beside a non-empty `sort`.
    private static func typedOptions(_ options: QueryOptions?, sort: [ModelSort<Self>]) throws -> QueryOptions? {
        guard !sort.isEmpty else { return options }
        var out = options ?? QueryOptions()
        guard out.sort == nil, out.sortOrder == nil else {
            throw JsBaoError(
                code: .invalidArgument,
                message: "A typed query names its sort in `sort:`; pass `options` without `sort` or `sortOrder` beside it."
            )
        }
        out.sortOrder = sort.map { ($0.field, $0.direction) }
        return out
    }

    private static func typedPage(_ page: PagedQueryResult<PrimitiveRow>) -> PagedQueryResult<Self> {
        PagedQueryResult(
            data: PrimitiveRowDecoder.decodeAll(page.data, as: Self.self),
            nextCursor: page.nextCursor,
            prevCursor: page.prevCursor,
            hasMore: page.hasMore,
            drift: page.drift
        )
    }
}
