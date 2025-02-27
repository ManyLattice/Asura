//
// Created by Mengyu Li on 2021/9/16.
//

@_implementationOnly import CLevelDB
import struct Foundation.Data
import Darwin

public class Database {
    let path: String
    let pointer: OpaquePointer

    private let writeOption: WriteOption
    private let readOption: ReadOption

    public init(path: String, option: Option = .default, writeOption: WriteOption = .default, readOption: ReadOption = .default) throws {
        func create() throws -> OpaquePointer {
            var errorPointer: UnsafeMutablePointer<Int8>?
            guard let pointer = leveldb_open(option.pointer, path, &errorPointer) else {
                var message: String?
                if let error = errorPointer {
                    defer { leveldb_free(error) }
                    message = String(cString: error)
                }
                throw LevelDBError.open(message: message)
            }
            return pointer
        }

        pointer = try create()

        self.path = path
        self.writeOption = writeOption
        self.readOption = readOption
    }

    deinit {
        leveldb_close(pointer)
    }
}

public extension Database {
    func put<Value: DataEncodable>(key: String, value: Value) throws {
        let valueData = try value.toData()
        var errorPointer: UnsafeMutablePointer<Int8>?

        key.slice { keyBytes, keyCount in
            valueData.withUnsafeBytes({ rawBufferPointer in
                leveldb_put(pointer, writeOption.pointer, keyBytes, keyCount, rawBufferPointer.baseAddress!.assumingMemoryBound(to: Int8.self), valueData.count, &errorPointer)
            })
        }
    }

    func get<Value: DataDecodable>(key: String) throws -> Value? {
        var valueLength = 0
        var error: UnsafeMutablePointer<Int8>?
        var value: UnsafeMutablePointer<Int8>?

        key.slice { bytes, len in
            value = leveldb_get(pointer, readOption.pointer, bytes, len, &valueLength, &error)
        }
        
        // check fetch value lenght
        guard valueLength > 0 else {
            return nil
        }
        let target = Data(bytes: value!, count: valueLength)
        free(value)
        
        return try .init(data: target)
    }

    /// Get the collection of keys corresponding to all data in the database
    func keys() -> [Slice] {
        let iterator = leveldb_create_iterator(pointer, readOption.pointer)
        leveldb_iter_seek_to_first(iterator)
        var keys = [Slice]()
        while leveldb_iter_valid(iterator) == 1 {
            var len = 0
            let result: UnsafePointer<Int8> = leveldb_iter_key(iterator, &len)
            let data = Data(bytes: result, count: len)
            keys.append(data)
            leveldb_iter_next(iterator)
        }
        return keys
    }
    
    func delete(key: String) throws {
        var errorPointer: UnsafeMutablePointer<Int8>?
        leveldb_delete(pointer, writeOption.pointer, key, key.utf8.count, &errorPointer)
        if let error = errorPointer {
            let message = String(cString: error)
            throw LevelDBError.delete(message: message)
        }
    }

    func writeBatch(_ batch: WriteBatch) throws {
        var errorPointer: UnsafeMutablePointer<Int8>?
        leveldb_write(pointer, writeOption.pointer, batch.pointer, &errorPointer)
        if let error = errorPointer {
            let message = String(cString: error)
            defer { leveldb_free(error) }
            throw LevelDBError.writeBatch(message: message)
        }
    }
}

public extension Database {
    func iterator(reverse: Bool = false, startKey: String? = nil, action: (_ key: String, _ valueData: Data, _ stop: inout Bool) -> Void) throws {
        let iterator = leveldb_create_iterator(pointer, readOption.pointer)
        defer { leveldb_iter_destroy(iterator) }

        let `init` = {
            if let startKey = startKey {
                leveldb_iter_seek(iterator, startKey, startKey.count)
            } else {
                switch reverse {
                case true:
                    leveldb_iter_seek_to_last(iterator)
                case false:
                    leveldb_iter_seek_to_first(iterator)
                }
            }
        }
        let go = {
            switch reverse {
            case true:
                leveldb_iter_prev(iterator)
            case false:
                leveldb_iter_next(iterator)
            }
        }

        `init`()
        while leveldb_iter_valid(iterator) != 0 {
            var keyLength = 0
            var valueLength = 0
            if let keyPointer = leveldb_iter_key(iterator, &keyLength),
               let valuePointer = leveldb_iter_value(iterator, &valueLength)
            {
                let keyData = Data(bytes: keyPointer, count: keyLength)
                let value = Data(bytes: valuePointer, count: valueLength)
                if let key = String(data: keyData, encoding: .utf8) {
                    var stop = false
                    action(key, value, &stop)

                    if stop { break }
                }
            }
            go()
        }

        var errorPointer: UnsafeMutablePointer<Int8>?
        leveldb_iter_get_error(iterator, &errorPointer)
        if let error = errorPointer {
            let message = String(cString: error)
            defer { leveldb_free(error) }
            throw LevelDBError.iterator(message: message)
        }
    }
}

public extension Database {
    func getProperty(_ property: Property) -> String? {
        guard let value = leveldb_property_value(pointer, property.rawValue) else { return nil }
        defer { leveldb_free(value) }
        return String(cString: value)
    }
}

public extension Database {
    func compact(beginKey: String? = nil, endKey: String? = nil) {
        leveldb_compact_range(pointer, beginKey, beginKey?.count ?? 0, endKey, endKey?.count ?? 0)
    }
}
