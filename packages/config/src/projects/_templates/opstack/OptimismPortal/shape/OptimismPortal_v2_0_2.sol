// SPDX-License-Identifier: Unknown
pragma solidity 0.8.20;

library AddressAliasHelper {
    uint160 constant offset = uint160(0x1111000000000000000000000000000000001111);

    /// @notice Utility function that converts the address in the L1 that submitted a tx to
    /// the inbox to the msg.sender viewed in the L2
    /// @param l1Address the address in the L1 that triggered the tx to L2
    /// @return l2Address L2 address as viewed in msg.sender
    function applyL1ToL2Alias(address l1Address) internal pure returns (address l2Address) {
        unchecked {
            l2Address = address(uint160(l1Address) + offset);
        }
    }

    /// @notice Utility function that converts the msg.sender viewed in the L2 to the
    /// address in the L1 that submitted a tx to the inbox
    /// @param l2Address L2 address as viewed in msg.sender
    /// @return l1Address the address in the L1 that triggered the tx to L2
    function undoL1ToL2Alias(address l2Address) internal pure returns (address l1Address) {
        unchecked {
            l1Address = address(uint160(l2Address) - offset);
        }
    }
}

library SafeCall {
    /// @notice Performs a low level call without copying any returndata.
    /// @dev Passes no calldata to the call context.
    /// @param _target   Address to call
    /// @param _gas      Amount of gas to pass to the call
    /// @param _value    Amount of value to pass to the call
    function send(address _target, uint256 _gas, uint256 _value) internal returns (bool) {
        bool _success;
        assembly {
            _success :=
                call(
                    _gas, // gas
                    _target, // recipient
                    _value, // ether value
                    0, // inloc
                    0, // inlen
                    0, // outloc
                    0 // outlen
                )
        }
        return _success;
    }

    /// @notice Perform a low level call with all gas without copying any returndata
    /// @param _target   Address to call
    /// @param _value    Amount of value to pass to the call
    function send(address _target, uint256 _value) internal returns (bool success_) {
        success_ = send(_target, gasleft(), _value);
    }

    /// @notice Perform a low level call without copying any returndata
    /// @param _target   Address to call
    /// @param _gas      Amount of gas to pass to the call
    /// @param _value    Amount of value to pass to the call
    /// @param _calldata Calldata to pass to the call
    function call(address _target, uint256 _gas, uint256 _value, bytes memory _calldata) internal returns (bool) {
        bool _success;
        assembly {
            _success :=
                call(
                    _gas, // gas
                    _target, // recipient
                    _value, // ether value
                    add(_calldata, 32), // inloc
                    mload(_calldata), // inlen
                    0, // outloc
                    0 // outlen
                )
        }
        return _success;
    }

    /// @notice Helper function to determine if there is sufficient gas remaining within the context
    ///         to guarantee that the minimum gas requirement for a call will be met as well as
    ///         optionally reserving a specified amount of gas for after the call has concluded.
    /// @param _minGas      The minimum amount of gas that may be passed to the target context.
    /// @param _reservedGas Optional amount of gas to reserve for the caller after the execution
    ///                     of the target context.
    /// @return `true` if there is enough gas remaining to safely supply `_minGas` to the target
    ///         context as well as reserve `_reservedGas` for the caller after the execution of
    ///         the target context.
    /// @dev !!!!! FOOTGUN ALERT !!!!!
    ///      1.) The 40_000 base buffer is to account for the worst case of the dynamic cost of the
    ///          `CALL` opcode's `address_access_cost`, `positive_value_cost`, and
    ///          `value_to_empty_account_cost` factors with an added buffer of 5,700 gas. It is
    ///          still possible to self-rekt by initiating a withdrawal with a minimum gas limit
    ///          that does not account for the `memory_expansion_cost` & `code_execution_cost`
    ///          factors of the dynamic cost of the `CALL` opcode.
    ///      2.) This function should *directly* precede the external call if possible. There is an
    ///          added buffer to account for gas consumed between this check and the call, but it
    ///          is only 5,700 gas.
    ///      3.) Because EIP-150 ensures that a maximum of 63/64ths of the remaining gas in the call
    ///          frame may be passed to a subcontext, we need to ensure that the gas will not be
    ///          truncated.
    ///      4.) Use wisely. This function is not a silver bullet.
    function hasMinGas(uint256 _minGas, uint256 _reservedGas) internal view returns (bool) {
        bool _hasMinGas;
        assembly {
            // Equation: gas × 63 ≥ minGas × 64 + 63(40_000 + reservedGas)
            _hasMinGas := iszero(lt(mul(gas(), 63), add(mul(_minGas, 64), mul(add(40000, _reservedGas), 63))))
        }
        return _hasMinGas;
    }

    /// @notice Perform a low level call without copying any returndata. This function
    ///         will revert if the call cannot be performed with the specified minimum
    ///         gas.
    /// @param _target   Address to call
    /// @param _minGas   The minimum amount of gas that may be passed to the call
    /// @param _value    Amount of value to pass to the call
    /// @param _calldata Calldata to pass to the call
    function callWithMinGas(
        address _target,
        uint256 _minGas,
        uint256 _value,
        bytes memory _calldata
    )
        internal
        returns (bool)
    {
        bool _success;
        bool _hasMinGas = hasMinGas(_minGas, 0);
        assembly {
            // Assertion: gasleft() >= (_minGas * 64) / 63 + 40_000
            if iszero(_hasMinGas) {
                // Store the "Error(string)" selector in scratch space.
                mstore(0, 0x08c379a0)
                // Store the pointer to the string length in scratch space.
                mstore(32, 32)
                // Store the string.
                //
                // SAFETY:
                // - We pad the beginning of the string with two zero bytes as well as the
                // length (24) to ensure that we override the free memory pointer at offset
                // 0x40. This is necessary because the free memory pointer is likely to
                // be greater than 1 byte when this function is called, but it is incredibly
                // unlikely that it will be greater than 3 bytes. As for the data within
                // 0x60, it is ensured that it is 0 due to 0x60 being the zero offset.
                // - It's fine to clobber the free memory pointer, we're reverting.
                mstore(88, 0x0000185361666543616c6c3a204e6f7420656e6f75676820676173)

                // Revert with 'Error("SafeCall: Not enough gas")'
                revert(28, 100)
            }

            // The call will be supplied at least ((_minGas * 64) / 63) gas due to the
            // above assertion. This ensures that, in all circumstances (except for when the
            // `_minGas` does not account for the `memory_expansion_cost` and `code_execution_cost`
            // factors of the dynamic cost of the `CALL` opcode), the call will receive at least
            // the minimum amount of gas specified.
            _success :=
                call(
                    gas(), // gas
                    _target, // recipient
                    _value, // ether value
                    add(_calldata, 32), // inloc
                    mload(_calldata), // inlen
                    0x00, // outloc
                    0x00 // outlen
                )
        }
        return _success;
    }
}

library RLPReader {
    /// @notice Custom pointer type to avoid confusion between pointers and uint256s.
    type MemoryPointer is uint256;

    /// @notice RLP item types.
    /// @custom:value DATA_ITEM Represents an RLP data item (NOT a list).
    /// @custom:value LIST_ITEM Represents an RLP list item.
    enum RLPItemType {
        DATA_ITEM,
        LIST_ITEM
    }

    /// @notice Struct representing an RLP item.
    /// @custom:field length Length of the RLP item.
    /// @custom:field ptr    Pointer to the RLP item in memory.
    struct RLPItem {
        uint256 length;
        MemoryPointer ptr;
    }

    /// @notice Max list length that this library will accept.
    uint256 internal constant MAX_LIST_LENGTH = 32;

    /// @notice Converts bytes to a reference to memory position and length.
    /// @param _in Input bytes to convert.
    /// @return out_ Output memory reference.
    function toRLPItem(bytes memory _in) internal pure returns (RLPItem memory out_) {
        // Empty arrays are not RLP items.
        require(_in.length > 0, "RLPReader: length of an RLP item must be greater than zero to be decodable");

        MemoryPointer ptr;
        assembly {
            ptr := add(_in, 32)
        }

        out_ = RLPItem({ length: _in.length, ptr: ptr });
    }

    /// @notice Reads an RLP list value into a list of RLP items.
    /// @param _in RLP list value.
    /// @return out_ Decoded RLP list items.
    function readList(RLPItem memory _in) internal pure returns (RLPItem[] memory out_) {
        (uint256 listOffset, uint256 listLength, RLPItemType itemType) = _decodeLength(_in);

        require(itemType == RLPItemType.LIST_ITEM, "RLPReader: decoded item type for list is not a list item");

        require(listOffset + listLength == _in.length, "RLPReader: list item has an invalid data remainder");

        // Solidity in-memory arrays can't be increased in size, but *can* be decreased in size by
        // writing to the length. Since we can't know the number of RLP items without looping over
        // the entire input, we'd have to loop twice to accurately size this array. It's easier to
        // simply set a reasonable maximum list length and decrease the size before we finish.
        out_ = new RLPItem[](MAX_LIST_LENGTH);

        uint256 itemCount = 0;
        uint256 offset = listOffset;
        while (offset < _in.length) {
            (uint256 itemOffset, uint256 itemLength,) = _decodeLength(
                RLPItem({ length: _in.length - offset, ptr: MemoryPointer.wrap(MemoryPointer.unwrap(_in.ptr) + offset) })
            );

            // We don't need to check itemCount < out.length explicitly because Solidity already
            // handles this check on our behalf, we'd just be wasting gas.
            out_[itemCount] = RLPItem({
                length: itemLength + itemOffset,
                ptr: MemoryPointer.wrap(MemoryPointer.unwrap(_in.ptr) + offset)
            });

            itemCount += 1;
            offset += itemOffset + itemLength;
        }

        // Decrease the array size to match the actual item count.
        assembly {
            mstore(out_, itemCount)
        }
    }

    /// @notice Reads an RLP list value into a list of RLP items.
    /// @param _in RLP list value.
    /// @return out_ Decoded RLP list items.
    function readList(bytes memory _in) internal pure returns (RLPItem[] memory out_) {
        out_ = readList(toRLPItem(_in));
    }

    /// @notice Reads an RLP bytes value into bytes.
    /// @param _in RLP bytes value.
    /// @return out_ Decoded bytes.
    function readBytes(RLPItem memory _in) internal pure returns (bytes memory out_) {
        (uint256 itemOffset, uint256 itemLength, RLPItemType itemType) = _decodeLength(_in);

        require(itemType == RLPItemType.DATA_ITEM, "RLPReader: decoded item type for bytes is not a data item");

        require(_in.length == itemOffset + itemLength, "RLPReader: bytes value contains an invalid remainder");

        out_ = _copy(_in.ptr, itemOffset, itemLength);
    }

    /// @notice Reads an RLP bytes value into bytes.
    /// @param _in RLP bytes value.
    /// @return out_ Decoded bytes.
    function readBytes(bytes memory _in) internal pure returns (bytes memory out_) {
        out_ = readBytes(toRLPItem(_in));
    }

    /// @notice Reads the raw bytes of an RLP item.
    /// @param _in RLP item to read.
    /// @return out_ Raw RLP bytes.
    function readRawBytes(RLPItem memory _in) internal pure returns (bytes memory out_) {
        out_ = _copy(_in.ptr, 0, _in.length);
    }

    /// @notice Decodes the length of an RLP item.
    /// @param _in RLP item to decode.
    /// @return offset_ Offset of the encoded data.
    /// @return length_ Length of the encoded data.
    /// @return type_ RLP item type (LIST_ITEM or DATA_ITEM).
    function _decodeLength(RLPItem memory _in)
        private
        pure
        returns (uint256 offset_, uint256 length_, RLPItemType type_)
    {
        // Short-circuit if there's nothing to decode, note that we perform this check when
        // the user creates an RLP item via toRLPItem, but it's always possible for them to bypass
        // that function and create an RLP item directly. So we need to check this anyway.
        require(_in.length > 0, "RLPReader: length of an RLP item must be greater than zero to be decodable");

        MemoryPointer ptr = _in.ptr;
        uint256 prefix;
        assembly {
            prefix := byte(0, mload(ptr))
        }

        if (prefix <= 0x7f) {
            // Single byte.
            return (0, 1, RLPItemType.DATA_ITEM);
        } else if (prefix <= 0xb7) {
            // Short string.

            // slither-disable-next-line variable-scope
            uint256 strLen = prefix - 0x80;

            require(
                _in.length > strLen, "RLPReader: length of content must be greater than string length (short string)"
            );

            bytes1 firstByteOfContent;
            assembly {
                firstByteOfContent := and(mload(add(ptr, 1)), shl(248, 0xff))
            }

            require(
                strLen != 1 || firstByteOfContent >= 0x80,
                "RLPReader: invalid prefix, single byte < 0x80 are not prefixed (short string)"
            );

            return (1, strLen, RLPItemType.DATA_ITEM);
        } else if (prefix <= 0xbf) {
            // Long string.
            uint256 lenOfStrLen = prefix - 0xb7;

            require(
                _in.length > lenOfStrLen,
                "RLPReader: length of content must be > than length of string length (long string)"
            );

            bytes1 firstByteOfContent;
            assembly {
                firstByteOfContent := and(mload(add(ptr, 1)), shl(248, 0xff))
            }

            require(
                firstByteOfContent != 0x00, "RLPReader: length of content must not have any leading zeros (long string)"
            );

            uint256 strLen;
            assembly {
                strLen := shr(sub(256, mul(8, lenOfStrLen)), mload(add(ptr, 1)))
            }

            require(strLen > 55, "RLPReader: length of content must be greater than 55 bytes (long string)");

            require(
                _in.length > lenOfStrLen + strLen,
                "RLPReader: length of content must be greater than total length (long string)"
            );

            return (1 + lenOfStrLen, strLen, RLPItemType.DATA_ITEM);
        } else if (prefix <= 0xf7) {
            // Short list.
            // slither-disable-next-line variable-scope
            uint256 listLen = prefix - 0xc0;

            require(_in.length > listLen, "RLPReader: length of content must be greater than list length (short list)");

            return (1, listLen, RLPItemType.LIST_ITEM);
        } else {
            // Long list.
            uint256 lenOfListLen = prefix - 0xf7;

            require(
                _in.length > lenOfListLen,
                "RLPReader: length of content must be > than length of list length (long list)"
            );

            bytes1 firstByteOfContent;
            assembly {
                firstByteOfContent := and(mload(add(ptr, 1)), shl(248, 0xff))
            }

            require(
                firstByteOfContent != 0x00, "RLPReader: length of content must not have any leading zeros (long list)"
            );

            uint256 listLen;
            assembly {
                listLen := shr(sub(256, mul(8, lenOfListLen)), mload(add(ptr, 1)))
            }

            require(listLen > 55, "RLPReader: length of content must be greater than 55 bytes (long list)");

            require(
                _in.length > lenOfListLen + listLen,
                "RLPReader: length of content must be greater than total length (long list)"
            );

            return (1 + lenOfListLen, listLen, RLPItemType.LIST_ITEM);
        }
    }

    /// @notice Copies the bytes from a memory location.
    /// @param _src    Pointer to the location to read from.
    /// @param _offset Offset to start reading from.
    /// @param _length Number of bytes to read.
    /// @return out_ Copied bytes.
    function _copy(MemoryPointer _src, uint256 _offset, uint256 _length) private pure returns (bytes memory out_) {
        out_ = new bytes(_length);
        if (_length == 0) {
            return out_;
        }

        // Mostly based on Solidity's copy_memory_to_memory:
        // https://github.com/ethereum/solidity/blob/34dd30d71b4da730488be72ff6af7083cf2a91f6/libsolidity/codegen/YulUtilFunctions.cpp#L102-L114
        uint256 src = MemoryPointer.unwrap(_src) + _offset;
        assembly {
            let dest := add(out_, 32)
            let i := 0
            for { } lt(i, _length) { i := add(i, 32) } { mstore(add(dest, i), mload(add(src, i))) }

            if gt(i, _length) { mstore(add(dest, _length), 0) }
        }
    }
}

library Bytes {
    /// @custom:attribution https://github.com/GNSPS/solidity-bytes-utils
    /// @notice Slices a byte array with a given starting index and length. Returns a new byte array
    ///         as opposed to a pointer to the original array. Will throw if trying to slice more
    ///         bytes than exist in the array.
    /// @param _bytes Byte array to slice.
    /// @param _start Starting index of the slice.
    /// @param _length Length of the slice.
    /// @return Slice of the input byte array.
    function slice(bytes memory _bytes, uint256 _start, uint256 _length) internal pure returns (bytes memory) {
        unchecked {
            require(_length + 31 >= _length, "slice_overflow");
            require(_start + _length >= _start, "slice_overflow");
            require(_bytes.length >= _start + _length, "slice_outOfBounds");
        }

        bytes memory tempBytes;

        assembly {
            switch iszero(_length)
            case 0 {
                // Get a location of some free memory and store it in tempBytes as
                // Solidity does for memory variables.
                tempBytes := mload(0x40)

                // The first word of the slice result is potentially a partial
                // word read from the original array. To read it, we calculate
                // the length of that partial word and start copying that many
                // bytes into the array. The first word we copy will start with
                // data we don't care about, but the last `lengthmod` bytes will
                // land at the beginning of the contents of the new array. When
                // we're done copying, we overwrite the full first word with
                // the actual length of the slice.
                let lengthmod := and(_length, 31)

                // The multiplication in the next line is necessary
                // because when slicing multiples of 32 bytes (lengthmod == 0)
                // the following copy loop was copying the origin's length
                // and then ending prematurely not copying everything it should.
                let mc := add(add(tempBytes, lengthmod), mul(0x20, iszero(lengthmod)))
                let end := add(mc, _length)

                for {
                    // The multiplication in the next line has the same exact purpose
                    // as the one above.
                    let cc := add(add(add(_bytes, lengthmod), mul(0x20, iszero(lengthmod))), _start)
                } lt(mc, end) {
                    mc := add(mc, 0x20)
                    cc := add(cc, 0x20)
                } { mstore(mc, mload(cc)) }

                mstore(tempBytes, _length)

                //update free-memory pointer
                //allocating the array padded to 32 bytes like the compiler does now
                mstore(0x40, and(add(mc, 31), not(31)))
            }
            //if we want a zero-length slice let's just return a zero-length array
            default {
                tempBytes := mload(0x40)

                //zero out the 32 bytes slice we are about to return
                //we need to do it because Solidity does not garbage collect
                mstore(tempBytes, 0)

                mstore(0x40, add(tempBytes, 0x20))
            }
        }

        return tempBytes;
    }

    /// @notice Slices a byte array with a given starting index up to the end of the original byte
    ///         array. Returns a new array rathern than a pointer to the original.
    /// @param _bytes Byte array to slice.
    /// @param _start Starting index of the slice.
    /// @return Slice of the input byte array.
    function slice(bytes memory _bytes, uint256 _start) internal pure returns (bytes memory) {
        if (_start >= _bytes.length) {
            return bytes("");
        }
        return slice(_bytes, _start, _bytes.length - _start);
    }

    /// @notice Converts a byte array into a nibble array by splitting each byte into two nibbles.
    ///         Resulting nibble array will be exactly twice as long as the input byte array.
    /// @param _bytes Input byte array to convert.
    /// @return Resulting nibble array.
    function toNibbles(bytes memory _bytes) internal pure returns (bytes memory) {
        bytes memory _nibbles;
        assembly {
            // Grab a free memory offset for the new array
            _nibbles := mload(0x40)

            // Load the length of the passed bytes array from memory
            let bytesLength := mload(_bytes)

            // Calculate the length of the new nibble array
            // This is the length of the input array times 2
            let nibblesLength := shl(0x01, bytesLength)

            // Update the free memory pointer to allocate memory for the new array.
            // To do this, we add the length of the new array + 32 bytes for the array length
            // rounded up to the nearest 32 byte boundary to the current free memory pointer.
            mstore(0x40, add(_nibbles, and(not(0x1F), add(nibblesLength, 0x3F))))

            // Store the length of the new array in memory
            mstore(_nibbles, nibblesLength)

            // Store the memory offset of the _bytes array's contents on the stack
            let bytesStart := add(_bytes, 0x20)

            // Store the memory offset of the nibbles array's contents on the stack
            let nibblesStart := add(_nibbles, 0x20)

            // Loop through each byte in the input array
            for { let i := 0x00 } lt(i, bytesLength) { i := add(i, 0x01) } {
                // Get the starting offset of the next 2 bytes in the nibbles array
                let offset := add(nibblesStart, shl(0x01, i))
                // Load the byte at the current index within the `_bytes` array
                let b := byte(0x00, mload(add(bytesStart, i)))

                // Pull out the first nibble and store it in the new array
                mstore8(offset, shr(0x04, b))
                // Pull out the second nibble and store it in the new array
                mstore8(add(offset, 0x01), and(b, 0x0F))
            }
        }
        return _nibbles;
    }

    /// @notice Compares two byte arrays by comparing their keccak256 hashes.
    /// @param _bytes First byte array to compare.
    /// @param _other Second byte array to compare.
    /// @return True if the two byte arrays are equal, false otherwise.
    function equal(bytes memory _bytes, bytes memory _other) internal pure returns (bool) {
        return keccak256(_bytes) == keccak256(_other);
    }
}

library MerkleTrie {
    /// @notice Struct representing a node in the trie.
    /// @custom:field encoded The RLP-encoded node.
    /// @custom:field decoded The RLP-decoded node.
    struct TrieNode {
        bytes encoded;
        RLPReader.RLPItem[] decoded;
    }

    /// @notice Determines the number of elements per branch node.
    uint256 internal constant TREE_RADIX = 16;

    /// @notice Branch nodes have TREE_RADIX elements and one value element.
    uint256 internal constant BRANCH_NODE_LENGTH = TREE_RADIX + 1;

    /// @notice Leaf nodes and extension nodes have two elements, a `path` and a `value`.
    uint256 internal constant LEAF_OR_EXTENSION_NODE_LENGTH = 2;

    /// @notice Prefix for even-nibbled extension node paths.
    uint8 internal constant PREFIX_EXTENSION_EVEN = 0;

    /// @notice Prefix for odd-nibbled extension node paths.
    uint8 internal constant PREFIX_EXTENSION_ODD = 1;

    /// @notice Prefix for even-nibbled leaf node paths.
    uint8 internal constant PREFIX_LEAF_EVEN = 2;

    /// @notice Prefix for odd-nibbled leaf node paths.
    uint8 internal constant PREFIX_LEAF_ODD = 3;

    /// @notice Verifies a proof that a given key/value pair is present in the trie.
    /// @param _key   Key of the node to search for, as a hex string.
    /// @param _value Value of the node to search for, as a hex string.
    /// @param _proof Merkle trie inclusion proof for the desired node. Unlike traditional Merkle
    ///               trees, this proof is executed top-down and consists of a list of RLP-encoded
    ///               nodes that make a path down to the target node.
    /// @param _root  Known root of the Merkle trie. Used to verify that the included proof is
    ///               correctly constructed.
    /// @return valid_ Whether or not the proof is valid.
    function verifyInclusionProof(
        bytes memory _key,
        bytes memory _value,
        bytes[] memory _proof,
        bytes32 _root
    )
        internal
        pure
        returns (bool valid_)
    {
        valid_ = Bytes.equal(_value, get(_key, _proof, _root));
    }

    /// @notice Retrieves the value associated with a given key.
    /// @param _key   Key to search for, as hex bytes.
    /// @param _proof Merkle trie inclusion proof for the key.
    /// @param _root  Known root of the Merkle trie.
    /// @return value_ Value of the key if it exists.
    function get(bytes memory _key, bytes[] memory _proof, bytes32 _root) internal pure returns (bytes memory value_) {
        require(_key.length > 0, "MerkleTrie: empty key");

        TrieNode[] memory proof = _parseProof(_proof);
        bytes memory key = Bytes.toNibbles(_key);
        bytes memory currentNodeID = abi.encodePacked(_root);
        uint256 currentKeyIndex = 0;

        // Proof is top-down, so we start at the first element (root).
        for (uint256 i = 0; i < proof.length; i++) {
            TrieNode memory currentNode = proof[i];

            // Key index should never exceed total key length or we'll be out of bounds.
            require(currentKeyIndex <= key.length, "MerkleTrie: key index exceeds total key length");

            if (currentKeyIndex == 0) {
                // First proof element is always the root node.
                require(
                    Bytes.equal(abi.encodePacked(keccak256(currentNode.encoded)), currentNodeID),
                    "MerkleTrie: invalid root hash"
                );
            } else if (currentNode.encoded.length >= 32) {
                // Nodes 32 bytes or larger are hashed inside branch nodes.
                require(
                    Bytes.equal(abi.encodePacked(keccak256(currentNode.encoded)), currentNodeID),
                    "MerkleTrie: invalid large internal hash"
                );
            } else {
                // Nodes smaller than 32 bytes aren't hashed.
                require(Bytes.equal(currentNode.encoded, currentNodeID), "MerkleTrie: invalid internal node hash");
            }

            if (currentNode.decoded.length == BRANCH_NODE_LENGTH) {
                if (currentKeyIndex == key.length) {
                    // Value is the last element of the decoded list (for branch nodes). There's
                    // some ambiguity in the Merkle trie specification because bytes(0) is a
                    // valid value to place into the trie, but for branch nodes bytes(0) can exist
                    // even when the value wasn't explicitly placed there. Geth treats a value of
                    // bytes(0) as "key does not exist" and so we do the same.
                    value_ = RLPReader.readBytes(currentNode.decoded[TREE_RADIX]);
                    require(value_.length > 0, "MerkleTrie: value length must be greater than zero (branch)");

                    // Extra proof elements are not allowed.
                    require(i == proof.length - 1, "MerkleTrie: value node must be last node in proof (branch)");

                    return value_;
                } else {
                    // We're not at the end of the key yet.
                    // Figure out what the next node ID should be and continue.
                    uint8 branchKey = uint8(key[currentKeyIndex]);
                    RLPReader.RLPItem memory nextNode = currentNode.decoded[branchKey];
                    currentNodeID = _getNodeID(nextNode);
                    currentKeyIndex += 1;
                }
            } else if (currentNode.decoded.length == LEAF_OR_EXTENSION_NODE_LENGTH) {
                bytes memory path = _getNodePath(currentNode);
                uint8 prefix = uint8(path[0]);
                uint8 offset = 2 - (prefix % 2);
                bytes memory pathRemainder = Bytes.slice(path, offset);
                bytes memory keyRemainder = Bytes.slice(key, currentKeyIndex);
                uint256 sharedNibbleLength = _getSharedNibbleLength(pathRemainder, keyRemainder);

                // Whether this is a leaf node or an extension node, the path remainder MUST be a
                // prefix of the key remainder (or be equal to the key remainder) or the proof is
                // considered invalid.
                require(
                    pathRemainder.length == sharedNibbleLength,
                    "MerkleTrie: path remainder must share all nibbles with key"
                );

                if (prefix == PREFIX_LEAF_EVEN || prefix == PREFIX_LEAF_ODD) {
                    // Prefix of 2 or 3 means this is a leaf node. For the leaf node to be valid,
                    // the key remainder must be exactly equal to the path remainder. We already
                    // did the necessary byte comparison, so it's more efficient here to check that
                    // the key remainder length equals the shared nibble length, which implies
                    // equality with the path remainder (since we already did the same check with
                    // the path remainder and the shared nibble length).
                    require(
                        keyRemainder.length == sharedNibbleLength,
                        "MerkleTrie: key remainder must be identical to path remainder"
                    );

                    // Our Merkle Trie is designed specifically for the purposes of the Ethereum
                    // state trie. Empty values are not allowed in the state trie, so we can safely
                    // say that if the value is empty, the key should not exist and the proof is
                    // invalid.
                    value_ = RLPReader.readBytes(currentNode.decoded[1]);
                    require(value_.length > 0, "MerkleTrie: value length must be greater than zero (leaf)");

                    // Extra proof elements are not allowed.
                    require(i == proof.length - 1, "MerkleTrie: value node must be last node in proof (leaf)");

                    return value_;
                } else if (prefix == PREFIX_EXTENSION_EVEN || prefix == PREFIX_EXTENSION_ODD) {
                    // Prefix of 0 or 1 means this is an extension node. We move onto the next node
                    // in the proof and increment the key index by the length of the path remainder
                    // which is equal to the shared nibble length.
                    currentNodeID = _getNodeID(currentNode.decoded[1]);
                    currentKeyIndex += sharedNibbleLength;
                } else {
                    revert("MerkleTrie: received a node with an unknown prefix");
                }
            } else {
                revert("MerkleTrie: received an unparseable node");
            }
        }

        revert("MerkleTrie: ran out of proof elements");
    }

    /// @notice Parses an array of proof elements into a new array that contains both the original
    ///         encoded element and the RLP-decoded element.
    /// @param _proof Array of proof elements to parse.
    /// @return proof_ Proof parsed into easily accessible structs.
    function _parseProof(bytes[] memory _proof) private pure returns (TrieNode[] memory proof_) {
        uint256 length = _proof.length;
        proof_ = new TrieNode[](length);
        for (uint256 i = 0; i < length;) {
            proof_[i] = TrieNode({ encoded: _proof[i], decoded: RLPReader.readList(_proof[i]) });
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Picks out the ID for a node. Node ID is referred to as the "hash" within the
    ///         specification, but nodes < 32 bytes are not actually hashed.
    /// @param _node Node to pull an ID for.
    /// @return id_ ID for the node, depending on the size of its contents.
    function _getNodeID(RLPReader.RLPItem memory _node) private pure returns (bytes memory id_) {
        id_ = _node.length < 32 ? RLPReader.readRawBytes(_node) : RLPReader.readBytes(_node);
    }

    /// @notice Gets the path for a leaf or extension node.
    /// @param _node Node to get a path for.
    /// @return nibbles_ Node path, converted to an array of nibbles.
    function _getNodePath(TrieNode memory _node) private pure returns (bytes memory nibbles_) {
        nibbles_ = Bytes.toNibbles(RLPReader.readBytes(_node.decoded[0]));
    }

    /// @notice Utility; determines the number of nibbles shared between two nibble arrays.
    /// @param _a First nibble array.
    /// @param _b Second nibble array.
    /// @return shared_ Number of shared nibbles.
    function _getSharedNibbleLength(bytes memory _a, bytes memory _b) private pure returns (uint256 shared_) {
        uint256 max = (_a.length < _b.length) ? _a.length : _b.length;
        for (; shared_ < max && _a[shared_] == _b[shared_];) {
            unchecked {
                ++shared_;
            }
        }
    }
}

library SecureMerkleTrie {
    /// @notice Verifies a proof that a given key/value pair is present in the Merkle trie.
    /// @param _key   Key of the node to search for, as a hex string.
    /// @param _value Value of the node to search for, as a hex string.
    /// @param _proof Merkle trie inclusion proof for the desired node. Unlike traditional Merkle
    ///               trees, this proof is executed top-down and consists of a list of RLP-encoded
    ///               nodes that make a path down to the target node.
    /// @param _root  Known root of the Merkle trie. Used to verify that the included proof is
    ///               correctly constructed.
    /// @return valid_ Whether or not the proof is valid.
    function verifyInclusionProof(
        bytes memory _key,
        bytes memory _value,
        bytes[] memory _proof,
        bytes32 _root
    )
        internal
        pure
        returns (bool valid_)
    {
        bytes memory key = _getSecureKey(_key);
        valid_ = MerkleTrie.verifyInclusionProof(key, _value, _proof, _root);
    }

    /// @notice Retrieves the value associated with a given key.
    /// @param _key   Key to search for, as hex bytes.
    /// @param _proof Merkle trie inclusion proof for the key.
    /// @param _root  Known root of the Merkle trie.
    /// @return value_ Value of the key if it exists.
    function get(bytes memory _key, bytes[] memory _proof, bytes32 _root) internal pure returns (bytes memory value_) {
        bytes memory key = _getSecureKey(_key);
        value_ = MerkleTrie.get(key, _proof, _root);
    }

    /// @notice Computes the hashed version of the input key.
    /// @param _key Key to hash.
    /// @return hash_ Hashed version of the key.
    function _getSecureKey(bytes memory _key) private pure returns (bytes memory hash_) {
        hash_ = abi.encodePacked(keccak256(_key));
    }
}

library RLPWriter {
    /// @notice RLP encodes a byte string.
    /// @param _in The byte string to encode.
    /// @return out_ The RLP encoded string in bytes.
    function writeBytes(bytes memory _in) internal pure returns (bytes memory out_) {
        if (_in.length == 1 && uint8(_in[0]) < 128) {
            out_ = _in;
        } else {
            out_ = abi.encodePacked(_writeLength(_in.length, 128), _in);
        }
    }

    /// @notice RLP encodes a list of RLP encoded byte byte strings.
    /// @param _in The list of RLP encoded byte strings.
    /// @return list_ The RLP encoded list of items in bytes.
    function writeList(bytes[] memory _in) internal pure returns (bytes memory list_) {
        list_ = _flatten(_in);
        list_ = abi.encodePacked(_writeLength(list_.length, 192), list_);
    }

    /// @notice RLP encodes a string.
    /// @param _in The string to encode.
    /// @return out_ The RLP encoded string in bytes.
    function writeString(string memory _in) internal pure returns (bytes memory out_) {
        out_ = writeBytes(bytes(_in));
    }

    /// @notice RLP encodes an address.
    /// @param _in The address to encode.
    /// @return out_ The RLP encoded address in bytes.
    function writeAddress(address _in) internal pure returns (bytes memory out_) {
        out_ = writeBytes(abi.encodePacked(_in));
    }

    /// @notice RLP encodes a uint.
    /// @param _in The uint256 to encode.
    /// @return out_ The RLP encoded uint256 in bytes.
    function writeUint(uint256 _in) internal pure returns (bytes memory out_) {
        out_ = writeBytes(_toBinary(_in));
    }

    /// @notice RLP encodes a bool.
    /// @param _in The bool to encode.
    /// @return out_ The RLP encoded bool in bytes.
    function writeBool(bool _in) internal pure returns (bytes memory out_) {
        out_ = new bytes(1);
        out_[0] = (_in ? bytes1(0x01) : bytes1(0x80));
    }

    /// @notice Encode the first byte and then the `len` in binary form if `length` is more than 55.
    /// @param _len    The length of the string or the payload.
    /// @param _offset 128 if item is string, 192 if item is list.
    /// @return out_ RLP encoded bytes.
    function _writeLength(uint256 _len, uint256 _offset) private pure returns (bytes memory out_) {
        if (_len < 56) {
            out_ = new bytes(1);
            out_[0] = bytes1(uint8(_len) + uint8(_offset));
        } else {
            uint256 lenLen;
            uint256 i = 1;
            while (_len / i != 0) {
                lenLen++;
                i *= 256;
            }

            out_ = new bytes(lenLen + 1);
            out_[0] = bytes1(uint8(lenLen) + uint8(_offset) + 55);
            for (i = 1; i <= lenLen; i++) {
                out_[i] = bytes1(uint8((_len / (256 ** (lenLen - i))) % 256));
            }
        }
    }

    /// @notice Encode integer in big endian binary form with no leading zeroes.
    /// @param _x The integer to encode.
    /// @return out_ RLP encoded bytes.
    function _toBinary(uint256 _x) private pure returns (bytes memory out_) {
        bytes memory b = abi.encodePacked(_x);

        uint256 i = 0;
        for (; i < 32; i++) {
            if (b[i] != 0) {
                break;
            }
        }

        out_ = new bytes(32 - i);
        for (uint256 j = 0; j < out_.length; j++) {
            out_[j] = b[i++];
        }
    }

    /// @custom:attribution https://github.com/Arachnid/solidity-stringutils
    /// @notice Copies a piece of memory to another location.
    /// @param _dest Destination location.
    /// @param _src  Source location.
    /// @param _len  Length of memory to copy.
    function _memcpy(uint256 _dest, uint256 _src, uint256 _len) private pure {
        uint256 dest = _dest;
        uint256 src = _src;
        uint256 len = _len;

        for (; len >= 32; len -= 32) {
            assembly {
                mstore(dest, mload(src))
            }
            dest += 32;
            src += 32;
        }

        uint256 mask;
        unchecked {
            mask = 256 ** (32 - len) - 1;
        }
        assembly {
            let srcpart := and(mload(src), not(mask))
            let destpart := and(mload(dest), mask)
            mstore(dest, or(destpart, srcpart))
        }
    }

    /// @custom:attribution https://github.com/sammayo/solidity-rlp-encoder
    /// @notice Flattens a list of byte strings into one byte string.
    /// @param _list List of byte strings to flatten.
    /// @return out_ The flattened byte string.
    function _flatten(bytes[] memory _list) private pure returns (bytes memory out_) {
        if (_list.length == 0) {
            return new bytes(0);
        }

        uint256 len;
        uint256 i = 0;
        for (; i < _list.length; i++) {
            len += _list[i].length;
        }

        out_ = new bytes(len);
        uint256 flattenedPtr;
        assembly {
            flattenedPtr := add(out_, 0x20)
        }

        for (i = 0; i < _list.length; i++) {
            bytes memory item = _list[i];

            uint256 listPtr;
            assembly {
                listPtr := add(item, 0x20)
            }

            _memcpy(flattenedPtr, listPtr, item.length);
            flattenedPtr += _list[i].length;
        }
    }
}

library Encoding {
    /// @notice RLP encodes the L2 transaction that would be generated when a given deposit is sent
    ///         to the L2 system. Useful for searching for a deposit in the L2 system. The
    ///         transaction is prefixed with 0x7e to identify its EIP-2718 type.
    /// @param _tx User deposit transaction to encode.
    /// @return RLP encoded L2 deposit transaction.
    function encodeDepositTransaction(Types.UserDepositTransaction memory _tx) internal pure returns (bytes memory) {
        bytes32 source = Hashing.hashDepositSource(_tx.l1BlockHash, _tx.logIndex);
        bytes[] memory raw = new bytes[](8);
        raw[0] = RLPWriter.writeBytes(abi.encodePacked(source));
        raw[1] = RLPWriter.writeAddress(_tx.from);
        raw[2] = _tx.isCreation ? RLPWriter.writeBytes("") : RLPWriter.writeAddress(_tx.to);
        raw[3] = RLPWriter.writeUint(_tx.mint);
        raw[4] = RLPWriter.writeUint(_tx.value);
        raw[5] = RLPWriter.writeUint(uint256(_tx.gasLimit));
        raw[6] = RLPWriter.writeBool(false);
        raw[7] = RLPWriter.writeBytes(_tx.data);
        return abi.encodePacked(uint8(0x7e), RLPWriter.writeList(raw));
    }

    /// @notice Encodes the cross domain message based on the version that is encoded into the
    ///         message nonce.
    /// @param _nonce    Message nonce with version encoded into the first two bytes.
    /// @param _sender   Address of the sender of the message.
    /// @param _target   Address of the target of the message.
    /// @param _value    ETH value to send to the target.
    /// @param _gasLimit Gas limit to use for the message.
    /// @param _data     Data to send with the message.
    /// @return Encoded cross domain message.
    function encodeCrossDomainMessage(
        uint256 _nonce,
        address _sender,
        address _target,
        uint256 _value,
        uint256 _gasLimit,
        bytes memory _data
    )
        internal
        pure
        returns (bytes memory)
    {
        (, uint16 version) = decodeVersionedNonce(_nonce);
        if (version == 0) {
            return encodeCrossDomainMessageV0(_target, _sender, _data, _nonce);
        } else if (version == 1) {
            return encodeCrossDomainMessageV1(_nonce, _sender, _target, _value, _gasLimit, _data);
        } else {
            revert("Encoding: unknown cross domain message version");
        }
    }

    /// @notice Encodes a cross domain message based on the V0 (legacy) encoding.
    /// @param _target Address of the target of the message.
    /// @param _sender Address of the sender of the message.
    /// @param _data   Data to send with the message.
    /// @param _nonce  Message nonce.
    /// @return Encoded cross domain message.
    function encodeCrossDomainMessageV0(
        address _target,
        address _sender,
        bytes memory _data,
        uint256 _nonce
    )
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodeWithSignature("relayMessage(address,address,bytes,uint256)", _target, _sender, _data, _nonce);
    }

    /// @notice Encodes a cross domain message based on the V1 (current) encoding.
    /// @param _nonce    Message nonce.
    /// @param _sender   Address of the sender of the message.
    /// @param _target   Address of the target of the message.
    /// @param _value    ETH value to send to the target.
    /// @param _gasLimit Gas limit to use for the message.
    /// @param _data     Data to send with the message.
    /// @return Encoded cross domain message.
    function encodeCrossDomainMessageV1(
        uint256 _nonce,
        address _sender,
        address _target,
        uint256 _value,
        uint256 _gasLimit,
        bytes memory _data
    )
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodeWithSignature(
            "relayMessage(uint256,address,address,uint256,uint256,bytes)",
            _nonce,
            _sender,
            _target,
            _value,
            _gasLimit,
            _data
        );
    }

    /// @notice Adds a version number into the first two bytes of a message nonce.
    /// @param _nonce   Message nonce to encode into.
    /// @param _version Version number to encode into the message nonce.
    /// @return Message nonce with version encoded into the first two bytes.
    function encodeVersionedNonce(uint240 _nonce, uint16 _version) internal pure returns (uint256) {
        uint256 nonce;
        assembly {
            nonce := or(shl(240, _version), _nonce)
        }
        return nonce;
    }

    /// @notice Pulls the version out of a version-encoded nonce.
    /// @param _nonce Message nonce with version encoded into the first two bytes.
    /// @return Nonce without encoded version.
    /// @return Version of the message.
    function decodeVersionedNonce(uint256 _nonce) internal pure returns (uint240, uint16) {
        uint240 nonce;
        uint16 version;
        assembly {
            nonce := and(_nonce, 0x0000ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff)
            version := shr(240, _nonce)
        }
        return (nonce, version);
    }

    /// @notice Returns an appropriately encoded call to L1Block.setL1BlockValuesEcotone
    /// @param baseFeeScalar       L1 base fee Scalar
    /// @param blobBaseFeeScalar   L1 blob base fee Scalar
    /// @param sequenceNumber      Number of L2 blocks since epoch start.
    /// @param timestamp           L1 timestamp.
    /// @param number              L1 blocknumber.
    /// @param baseFee             L1 base fee.
    /// @param blobBaseFee         L1 blob base fee.
    /// @param hash                L1 blockhash.
    /// @param batcherHash         Versioned hash to authenticate batcher by.
    function encodeSetL1BlockValuesEcotone(
        uint32 baseFeeScalar,
        uint32 blobBaseFeeScalar,
        uint64 sequenceNumber,
        uint64 timestamp,
        uint64 number,
        uint256 baseFee,
        uint256 blobBaseFee,
        bytes32 hash,
        bytes32 batcherHash
    )
        internal
        pure
        returns (bytes memory)
    {
        bytes4 functionSignature = bytes4(keccak256("setL1BlockValuesEcotone()"));
        return abi.encodePacked(
            functionSignature,
            baseFeeScalar,
            blobBaseFeeScalar,
            sequenceNumber,
            timestamp,
            number,
            baseFee,
            blobBaseFee,
            hash,
            batcherHash
        );
    }

    /// @notice Returns an appropriately encoded call to L1Block.setL1BlockValuesEcotoneExclusions
    /// @param baseFeeScalar       L1 base fee Scalar
    /// @param blobBaseFeeScalar   L1 blob base fee Scalar
    /// @param sequenceNumber      Number of L2 blocks since epoch start.
    /// @param timestamp           L1 timestamp.
    /// @param number              L1 blocknumber.
    /// @param baseFee             L1 base fee.
    /// @param blobBaseFee         L1 blob base fee.
    /// @param hash                L1 blockhash.
    /// @param batcherHash         Versioned hash to authenticate batcher by.
    function encodeSetL1BlockValuesEcotoneExclusions(
        uint32 baseFeeScalar,
        uint32 blobBaseFeeScalar,
        uint64 sequenceNumber,
        uint64 timestamp,
        uint64 number,
        uint256 baseFee,
        uint256 blobBaseFee,
        bytes32 hash,
        bytes32 batcherHash,
        bytes memory depositExclusions
    )
        internal
        pure
        returns (bytes memory)
    {
        bytes4 functionSignature = bytes4(keccak256("setL1BlockValuesEcotoneExclusions()"));
        return abi.encodePacked(
            functionSignature,
            baseFeeScalar,
            blobBaseFeeScalar,
            sequenceNumber,
            timestamp,
            number,
            baseFee,
            blobBaseFee,
            hash,
            batcherHash,
            uint256(depositExclusions.length),
            depositExclusions
        );
    }
}

library Hashing {
    /// @notice Computes the hash of the RLP encoded L2 transaction that would be generated when a
    ///         given deposit is sent to the L2 system. Useful for searching for a deposit in the L2
    ///         system.
    /// @param _tx User deposit transaction to hash.
    /// @return Hash of the RLP encoded L2 deposit transaction.
    function hashDepositTransaction(Types.UserDepositTransaction memory _tx) internal pure returns (bytes32) {
        return keccak256(Encoding.encodeDepositTransaction(_tx));
    }

    /// @notice Computes the deposit transaction's "source hash", a value that guarantees the hash
    ///         of the L2 transaction that corresponds to a deposit is unique and is
    ///         deterministically generated from L1 transaction data.
    /// @param _l1BlockHash Hash of the L1 block where the deposit was included.
    /// @param _logIndex    The index of the log that created the deposit transaction.
    /// @return Hash of the deposit transaction's "source hash".
    function hashDepositSource(bytes32 _l1BlockHash, uint256 _logIndex) internal pure returns (bytes32) {
        bytes32 depositId = keccak256(abi.encode(_l1BlockHash, _logIndex));
        return keccak256(abi.encode(bytes32(0), depositId));
    }

    /// @notice Hashes the cross domain message based on the version that is encoded into the
    ///         message nonce.
    /// @param _nonce    Message nonce with version encoded into the first two bytes.
    /// @param _sender   Address of the sender of the message.
    /// @param _target   Address of the target of the message.
    /// @param _value    ETH value to send to the target.
    /// @param _gasLimit Gas limit to use for the message.
    /// @param _data     Data to send with the message.
    /// @return Hashed cross domain message.
    function hashCrossDomainMessage(
        uint256 _nonce,
        address _sender,
        address _target,
        uint256 _value,
        uint256 _gasLimit,
        bytes memory _data
    )
        internal
        pure
        returns (bytes32)
    {
        (, uint16 version) = Encoding.decodeVersionedNonce(_nonce);
        if (version == 0) {
            return hashCrossDomainMessageV0(_target, _sender, _data, _nonce);
        } else if (version == 1) {
            return hashCrossDomainMessageV1(_nonce, _sender, _target, _value, _gasLimit, _data);
        } else {
            revert("Hashing: unknown cross domain message version");
        }
    }

    /// @notice Hashes a cross domain message based on the V0 (legacy) encoding.
    /// @param _target Address of the target of the message.
    /// @param _sender Address of the sender of the message.
    /// @param _data   Data to send with the message.
    /// @param _nonce  Message nonce.
    /// @return Hashed cross domain message.
    function hashCrossDomainMessageV0(
        address _target,
        address _sender,
        bytes memory _data,
        uint256 _nonce
    )
        internal
        pure
        returns (bytes32)
    {
        return keccak256(Encoding.encodeCrossDomainMessageV0(_target, _sender, _data, _nonce));
    }

    /// @notice Hashes a cross domain message based on the V1 (current) encoding.
    /// @param _nonce    Message nonce.
    /// @param _sender   Address of the sender of the message.
    /// @param _target   Address of the target of the message.
    /// @param _value    ETH value to send to the target.
    /// @param _gasLimit Gas limit to use for the message.
    /// @param _data     Data to send with the message.
    /// @return Hashed cross domain message.
    function hashCrossDomainMessageV1(
        uint256 _nonce,
        address _sender,
        address _target,
        uint256 _value,
        uint256 _gasLimit,
        bytes memory _data
    )
        internal
        pure
        returns (bytes32)
    {
        return keccak256(Encoding.encodeCrossDomainMessageV1(_nonce, _sender, _target, _value, _gasLimit, _data));
    }

    /// @notice Derives the withdrawal hash according to the encoding in the L2 Withdrawer contract
    /// @param _tx Withdrawal transaction to hash.
    /// @return Hashed withdrawal transaction.
    function hashWithdrawal(Types.WithdrawalTransaction memory _tx) internal pure returns (bytes32) {
        return keccak256(abi.encode(_tx.nonce, _tx.sender, _tx.target, _tx.value, _tx.gasLimit, _tx.data));
    }

    /// @notice Hashes the various elements of an output root proof into an output root hash which
    ///         can be used to check if the proof is valid.
    /// @param _outputRootProof Output root proof which should hash to an output root.
    /// @return Hashed output root proof.
    function hashOutputRootProof(Types.OutputRootProof memory _outputRootProof) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                _outputRootProof.version,
                _outputRootProof.stateRoot,
                _outputRootProof.messagePasserStorageRoot,
                _outputRootProof.latestBlockhash
            )
        );
    }
}

library Types {
    /// @notice OutputProposal represents a commitment to the L2 state. The timestamp is the L1
    ///         timestamp that the output root is posted. This timestamp is used to verify that the
    ///         finalization period has passed since the output root was submitted.
    /// @custom:field outputRoot    Hash of the L2 output.
    /// @custom:field timestamp     Timestamp of the L1 block that the output root was submitted in.
    /// @custom:field l2BlockNumber L2 block number that the output corresponds to.
    struct OutputProposal {
        bytes32 outputRoot;
        uint128 timestamp;
        uint128 l2BlockNumber;
    }

    /// @notice Struct representing the elements that are hashed together to generate an output root
    ///         which itself represents a snapshot of the L2 state.
    /// @custom:field version                  Version of the output root.
    /// @custom:field stateRoot                Root of the state trie at the block of this output.
    /// @custom:field messagePasserStorageRoot Root of the message passer storage trie.
    /// @custom:field latestBlockhash          Hash of the block this output was generated from.
    struct OutputRootProof {
        bytes32 version;
        bytes32 stateRoot;
        bytes32 messagePasserStorageRoot;
        bytes32 latestBlockhash;
    }

    /// @notice Struct representing a deposit transaction (L1 => L2 transaction) created by an end
    ///         user (as opposed to a system deposit transaction generated by the system).
    /// @custom:field from        Address of the sender of the transaction.
    /// @custom:field to          Address of the recipient of the transaction.
    /// @custom:field isCreation  True if the transaction is a contract creation.
    /// @custom:field value       Value to send to the recipient.
    /// @custom:field mint        Amount of ETH to mint.
    /// @custom:field gasLimit    Gas limit of the transaction.
    /// @custom:field data        Data of the transaction.
    /// @custom:field l1BlockHash Hash of the block the transaction was submitted in.
    /// @custom:field logIndex    Index of the log in the block the transaction was submitted in.
    struct UserDepositTransaction {
        address from;
        address to;
        bool isCreation;
        uint256 value;
        uint256 mint;
        uint64 gasLimit;
        bytes data;
        bytes32 l1BlockHash;
        uint256 logIndex;
    }

    /// @notice Struct representing a withdrawal transaction.
    /// @custom:field nonce    Nonce of the withdrawal transaction
    /// @custom:field sender   Address of the sender of the transaction.
    /// @custom:field target   Address of the recipient of the transaction.
    /// @custom:field value    Value to send to the recipient.
    /// @custom:field gasLimit Gas limit of the transaction.
    /// @custom:field data     Data of the transaction.
    struct WithdrawalTransaction {
        uint256 nonce;
        address sender;
        address target;
        uint256 value;
        uint256 gasLimit;
        bytes data;
    }
}

library Constants {
    /// @notice Special address to be used as the tx origin for gas estimation calls in the
    ///         OptimismPortal and CrossDomainMessenger calls. You only need to use this address if
    ///         the minimum gas limit specified by the user is not actually enough to execute the
    ///         given message and you're attempting to estimate the actual necessary gas limit. We
    ///         use address(1) because it's the ecrecover precompile and therefore guaranteed to
    ///         never have any code on any EVM chain.
    address internal constant ESTIMATION_ADDRESS = address(1);

    /// @notice Value used for the L2 sender storage slot in both the OptimismPortal and the
    ///         CrossDomainMessenger contracts before an actual sender is set. This value is
    ///         non-zero to reduce the gas cost of message passing transactions.
    address internal constant DEFAULT_L2_SENDER = 0x000000000000000000000000000000000000dEaD;

    /// @notice The storage slot that holds the address of a proxy implementation.
    /// @dev `bytes32(uint256(keccak256('eip1967.proxy.implementation')) - 1)`
    bytes32 internal constant PROXY_IMPLEMENTATION_ADDRESS =
    0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    /// @notice The storage slot that holds the address of the owner.
    /// @dev `bytes32(uint256(keccak256('eip1967.proxy.admin')) - 1)`
    bytes32 internal constant PROXY_OWNER_ADDRESS = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    /// @notice Returns the default values for the ResourceConfig. These are the recommended values
    ///         for a production network.
    function DEFAULT_RESOURCE_CONFIG() internal pure returns (ResourceMetering.ResourceConfig memory) {
        ResourceMetering.ResourceConfig memory config = ResourceMetering.ResourceConfig({
            maxResourceLimit: 20_000_000,
            elasticityMultiplier: 10,
            baseFeeMaxChangeDenominator: 8,
            maxTransactionLimit: 8,
            minimumBaseFee: 1 gwei,
            systemTxMaxGas: 1_000_000,
            maximumBaseFee: type(uint128).max
        });
        return config;
    }
}

interface ISemver {
    /// @notice Getter for the semantic version of the contract. This is not
    ///         meant to be used onchain but instead meant to be used by offchain
    ///         tooling.
    /// @return Semver contract version as a string.
    function version() external view returns (string memory);
}

library Math {
    /**
     * @dev Muldiv operation overflow.
     */
    error MathOverflowedMulDiv();

    enum Rounding {
        Floor, // Toward negative infinity
        Ceil, // Toward positive infinity
        Trunc, // Toward zero
        Expand // Away from zero
    }

    /**
     * @dev Returns the addition of two unsigned integers, with an overflow flag.
     */
    function tryAdd(uint256 a, uint256 b) internal pure returns (bool, uint256) {
        unchecked {
            uint256 c = a + b;
            if (c < a) return (false, 0);
            return (true, c);
        }
    }

    /**
     * @dev Returns the subtraction of two unsigned integers, with an overflow flag.
     */
    function trySub(uint256 a, uint256 b) internal pure returns (bool, uint256) {
        unchecked {
            if (b > a) return (false, 0);
            return (true, a - b);
        }
    }

    /**
     * @dev Returns the multiplication of two unsigned integers, with an overflow flag.
     */
    function tryMul(uint256 a, uint256 b) internal pure returns (bool, uint256) {
        unchecked {
            // Gas optimization: this is cheaper than requiring 'a' not being zero, but the
            // benefit is lost if 'b' is also tested.
            // See: https://github.com/OpenZeppelin/openzeppelin-contracts/pull/522
            if (a == 0) return (true, 0);
            uint256 c = a * b;
            if (c / a != b) return (false, 0);
            return (true, c);
        }
    }

    /**
     * @dev Returns the division of two unsigned integers, with a division by zero flag.
     */
    function tryDiv(uint256 a, uint256 b) internal pure returns (bool, uint256) {
        unchecked {
            if (b == 0) return (false, 0);
            return (true, a / b);
        }
    }

    /**
     * @dev Returns the remainder of dividing two unsigned integers, with a division by zero flag.
     */
    function tryMod(uint256 a, uint256 b) internal pure returns (bool, uint256) {
        unchecked {
            if (b == 0) return (false, 0);
            return (true, a % b);
        }
    }

    /**
     * @dev Returns the largest of two numbers.
     */
    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }

    /**
     * @dev Returns the smallest of two numbers.
     */
    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    /**
     * @dev Returns the average of two numbers. The result is rounded towards
     * zero.
     */
    function average(uint256 a, uint256 b) internal pure returns (uint256) {
        // (a + b) / 2 can overflow.
        return (a & b) + (a ^ b) / 2;
    }

    /**
     * @dev Returns the ceiling of the division of two numbers.
     *
     * This differs from standard division with `/` in that it rounds towards infinity instead
     * of rounding towards zero.
     */
    function ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        if (b == 0) {
            // Guarantee the same behavior as in a regular Solidity division.
            return a / b;
        }

        // (a + b - 1) / b can overflow on addition, so we distribute.
        return a == 0 ? 0 : (a - 1) / b + 1;
    }

    /**
     * @notice Calculates floor(x * y / denominator) with full precision. Throws if result overflows a uint256 or
     * denominator == 0.
     * @dev Original credit to Remco Bloemen under MIT license (https://xn--2-umb.com/21/muldiv) with further edits by
     * Uniswap Labs also under MIT license.
     */
    function mulDiv(uint256 x, uint256 y, uint256 denominator) internal pure returns (uint256 result) {
        unchecked {
            // 512-bit multiply [prod1 prod0] = x * y. Compute the product mod 2^256 and mod 2^256 - 1, then use
            // use the Chinese Remainder Theorem to reconstruct the 512 bit result. The result is stored in two 256
            // variables such that product = prod1 * 2^256 + prod0.
            uint256 prod0 = x * y; // Least significant 256 bits of the product
            uint256 prod1; // Most significant 256 bits of the product
            assembly {
                let mm := mulmod(x, y, not(0))
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }

            // Handle non-overflow cases, 256 by 256 division.
            if (prod1 == 0) {
                // Solidity will revert if denominator == 0, unlike the div opcode on its own.
                // The surrounding unchecked block does not change this fact.
                // See https://docs.soliditylang.org/en/latest/control-structures.html#checked-or-unchecked-arithmetic.
                return prod0 / denominator;
            }

            // Make sure the result is less than 2^256. Also prevents denominator == 0.
            if (denominator <= prod1) {
                revert MathOverflowedMulDiv();
            }

            ///////////////////////////////////////////////
            // 512 by 256 division.
            ///////////////////////////////////////////////

            // Make division exact by subtracting the remainder from [prod1 prod0].
            uint256 remainder;
            assembly {
                // Compute remainder using mulmod.
                remainder := mulmod(x, y, denominator)

                // Subtract 256 bit number from 512 bit number.
                prod1 := sub(prod1, gt(remainder, prod0))
                prod0 := sub(prod0, remainder)
            }

            // Factor powers of two out of denominator and compute largest power of two divisor of denominator.
            // Always >= 1. See https://cs.stackexchange.com/q/138556/92363.

            uint256 twos = denominator & (0 - denominator);
            assembly {
                // Divide denominator by twos.
                denominator := div(denominator, twos)

                // Divide [prod1 prod0] by twos.
                prod0 := div(prod0, twos)

                // Flip twos such that it is 2^256 / twos. If twos is zero, then it becomes one.
                twos := add(div(sub(0, twos), twos), 1)
            }

            // Shift in bits from prod1 into prod0.
            prod0 |= prod1 * twos;

            // Invert denominator mod 2^256. Now that denominator is an odd number, it has an inverse modulo 2^256 such
            // that denominator * inv = 1 mod 2^256. Compute the inverse by starting with a seed that is correct for
            // four bits. That is, denominator * inv = 1 mod 2^4.
            uint256 inverse = (3 * denominator) ^ 2;

            // Use the Newton-Raphson iteration to improve the precision. Thanks to Hensel's lifting lemma, this also
            // works in modular arithmetic, doubling the correct bits in each step.
            inverse *= 2 - denominator * inverse; // inverse mod 2^8
            inverse *= 2 - denominator * inverse; // inverse mod 2^16
            inverse *= 2 - denominator * inverse; // inverse mod 2^32
            inverse *= 2 - denominator * inverse; // inverse mod 2^64
            inverse *= 2 - denominator * inverse; // inverse mod 2^128
            inverse *= 2 - denominator * inverse; // inverse mod 2^256

            // Because the division is now exact we can divide by multiplying with the modular inverse of denominator.
            // This will give us the correct result modulo 2^256. Since the preconditions guarantee that the outcome is
            // less than 2^256, this is the final result. We don't need to compute the high bits of the result and prod1
            // is no longer required.
            result = prod0 * inverse;
            return result;
        }
    }

    /**
     * @notice Calculates x * y / denominator with full precision, following the selected rounding direction.
     */
    function mulDiv(uint256 x, uint256 y, uint256 denominator, Rounding rounding) internal pure returns (uint256) {
        uint256 result = mulDiv(x, y, denominator);
        if (unsignedRoundsUp(rounding) && mulmod(x, y, denominator) > 0) {
            result += 1;
        }
        return result;
    }

    /**
     * @dev Returns the square root of a number. If the number is not a perfect square, the value is rounded
     * towards zero.
     *
     * Inspired by Henry S. Warren, Jr.'s "Hacker's Delight" (Chapter 11).
     */
    function sqrt(uint256 a) internal pure returns (uint256) {
        if (a == 0) {
            return 0;
        }

        // For our first guess, we get the biggest power of 2 which is smaller than the square root of the target.
        //
        // We know that the "msb" (most significant bit) of our target number `a` is a power of 2 such that we have
        // `msb(a) <= a < 2*msb(a)`. This value can be written `msb(a)=2**k` with `k=log2(a)`.
        //
        // This can be rewritten `2**log2(a) <= a < 2**(log2(a) + 1)`
        // → `sqrt(2**k) <= sqrt(a) < sqrt(2**(k+1))`
        // → `2**(k/2) <= sqrt(a) < 2**((k+1)/2) <= 2**(k/2 + 1)`
        //
        // Consequently, `2**(log2(a) / 2)` is a good first approximation of `sqrt(a)` with at least 1 correct bit.
        uint256 result = 1 << (log2(a) >> 1);

        // At this point `result` is an estimation with one bit of precision. We know the true value is a uint128,
        // since it is the square root of a uint256. Newton's method converges quadratically (precision doubles at
        // every iteration). We thus need at most 7 iteration to turn our partial result with one bit of precision
        // into the expected uint128 result.
        unchecked {
            result = (result + a / result) >> 1;
            result = (result + a / result) >> 1;
            result = (result + a / result) >> 1;
            result = (result + a / result) >> 1;
            result = (result + a / result) >> 1;
            result = (result + a / result) >> 1;
            result = (result + a / result) >> 1;
            return min(result, a / result);
        }
    }

    /**
     * @notice Calculates sqrt(a), following the selected rounding direction.
     */
    function sqrt(uint256 a, Rounding rounding) internal pure returns (uint256) {
        unchecked {
            uint256 result = sqrt(a);
            return result + (unsignedRoundsUp(rounding) && result * result < a ? 1 : 0);
        }
    }

    /**
     * @dev Return the log in base 2 of a positive value rounded towards zero.
     * Returns 0 if given 0.
     */
    function log2(uint256 value) internal pure returns (uint256) {
        uint256 result = 0;
        unchecked {
            if (value >> 128 > 0) {
                value >>= 128;
                result += 128;
            }
            if (value >> 64 > 0) {
                value >>= 64;
                result += 64;
            }
            if (value >> 32 > 0) {
                value >>= 32;
                result += 32;
            }
            if (value >> 16 > 0) {
                value >>= 16;
                result += 16;
            }
            if (value >> 8 > 0) {
                value >>= 8;
                result += 8;
            }
            if (value >> 4 > 0) {
                value >>= 4;
                result += 4;
            }
            if (value >> 2 > 0) {
                value >>= 2;
                result += 2;
            }
            if (value >> 1 > 0) {
                result += 1;
            }
        }
        return result;
    }

    /**
     * @dev Return the log in base 2, following the selected rounding direction, of a positive value.
     * Returns 0 if given 0.
     */
    function log2(uint256 value, Rounding rounding) internal pure returns (uint256) {
        unchecked {
            uint256 result = log2(value);
            return result + (unsignedRoundsUp(rounding) && 1 << result < value ? 1 : 0);
        }
    }

    /**
     * @dev Return the log in base 10 of a positive value rounded towards zero.
     * Returns 0 if given 0.
     */
    function log10(uint256 value) internal pure returns (uint256) {
        uint256 result = 0;
        unchecked {
            if (value >= 10 ** 64) {
                value /= 10 ** 64;
                result += 64;
            }
            if (value >= 10 ** 32) {
                value /= 10 ** 32;
                result += 32;
            }
            if (value >= 10 ** 16) {
                value /= 10 ** 16;
                result += 16;
            }
            if (value >= 10 ** 8) {
                value /= 10 ** 8;
                result += 8;
            }
            if (value >= 10 ** 4) {
                value /= 10 ** 4;
                result += 4;
            }
            if (value >= 10 ** 2) {
                value /= 10 ** 2;
                result += 2;
            }
            if (value >= 10 ** 1) {
                result += 1;
            }
        }
        return result;
    }

    /**
     * @dev Return the log in base 10, following the selected rounding direction, of a positive value.
     * Returns 0 if given 0.
     */
    function log10(uint256 value, Rounding rounding) internal pure returns (uint256) {
        unchecked {
            uint256 result = log10(value);
            return result + (unsignedRoundsUp(rounding) && 10 ** result < value ? 1 : 0);
        }
    }

    /**
     * @dev Return the log in base 256 of a positive value rounded towards zero.
     * Returns 0 if given 0.
     *
     * Adding one to the result gives the number of pairs of hex symbols needed to represent `value` as a hex string.
     */
    function log256(uint256 value) internal pure returns (uint256) {
        uint256 result = 0;
        unchecked {
            if (value >> 128 > 0) {
                value >>= 128;
                result += 16;
            }
            if (value >> 64 > 0) {
                value >>= 64;
                result += 8;
            }
            if (value >> 32 > 0) {
                value >>= 32;
                result += 4;
            }
            if (value >> 16 > 0) {
                value >>= 16;
                result += 2;
            }
            if (value >> 8 > 0) {
                result += 1;
            }
        }
        return result;
    }

    /**
     * @dev Return the log in base 256, following the selected rounding direction, of a positive value.
     * Returns 0 if given 0.
     */
    function log256(uint256 value, Rounding rounding) internal pure returns (uint256) {
        unchecked {
            uint256 result = log256(value);
            return result + (unsignedRoundsUp(rounding) && 1 << (result << 3) < value ? 1 : 0);
        }
    }

    /**
     * @dev Returns whether a provided rounding mode is considered rounding up for unsigned integers.
     */
    function unsignedRoundsUp(Rounding rounding) internal pure returns (bool) {
        return uint8(rounding) % 2 == 1;
    }
}

library SignedMath {
    /**
     * @dev Returns the largest of two signed numbers.
     */
    function max(int256 a, int256 b) internal pure returns (int256) {
        return a > b ? a : b;
    }

    /**
     * @dev Returns the smallest of two signed numbers.
     */
    function min(int256 a, int256 b) internal pure returns (int256) {
        return a < b ? a : b;
    }

    /**
     * @dev Returns the average of two signed numbers without overflow.
     * The result is rounded towards zero.
     */
    function average(int256 a, int256 b) internal pure returns (int256) {
        // Formula from the book "Hacker's Delight"
        int256 x = (a & b) + ((a ^ b) >> 1);
        return x + (int256(uint256(x) >> 255) & (a ^ b));
    }

    /**
     * @dev Returns the absolute unsigned value of a signed value.
     */
    function abs(int256 n) internal pure returns (uint256) {
        unchecked {
            // must be unchecked in order to support `n = type(int256).min`
            return uint256(n >= 0 ? n : -n);
        }
    }
}

library FixedPointMathLib {
    /*//////////////////////////////////////////////////////////////
                    SIMPLIFIED FIXED POINT OPERATIONS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant WAD = 1e18; // The scalar of ETH and most ERC20s.

    function mulWadDown(uint256 x, uint256 y) internal pure returns (uint256) {
        return mulDivDown(x, y, WAD); // Equivalent to (x * y) / WAD rounded down.
    }

    function mulWadUp(uint256 x, uint256 y) internal pure returns (uint256) {
        return mulDivUp(x, y, WAD); // Equivalent to (x * y) / WAD rounded up.
    }

    function divWadDown(uint256 x, uint256 y) internal pure returns (uint256) {
        return mulDivDown(x, WAD, y); // Equivalent to (x * WAD) / y rounded down.
    }

    function divWadUp(uint256 x, uint256 y) internal pure returns (uint256) {
        return mulDivUp(x, WAD, y); // Equivalent to (x * WAD) / y rounded up.
    }

    function powWad(int256 x, int256 y) internal pure returns (int256) {
        // Equivalent to x to the power of y because x ** y = (e ** ln(x)) ** y = e ** (ln(x) * y)
        return expWad((lnWad(x) * y) / int256(WAD)); // Using ln(x) means x must be greater than 0.
    }

    function expWad(int256 x) internal pure returns (int256 r) {
        unchecked {
            // When the result is < 0.5 we return zero. This happens when
            // x <= floor(log(0.5e18) * 1e18) ~ -42e18
            if (x <= -42139678854452767551) return 0;

            // When the result is > (2**255 - 1) / 1e18 we can not represent it as an
            // int. This happens when x >= floor(log((2**255 - 1) / 1e18) * 1e18) ~ 135.
            if (x >= 135305999368893231589) revert("EXP_OVERFLOW");

            // x is now in the range (-42, 136) * 1e18. Convert to (-42, 136) * 2**96
            // for more intermediate precision and a binary basis. This base conversion
            // is a multiplication by 1e18 / 2**96 = 5**18 / 2**78.
            x = (x << 78) / 5**18;

            // Reduce range of x to (-½ ln 2, ½ ln 2) * 2**96 by factoring out powers
            // of two such that exp(x) = exp(x') * 2**k, where k is an integer.
            // Solving this gives k = round(x / log(2)) and x' = x - k * log(2).
            int256 k = ((x << 96) / 54916777467707473351141471128 + 2**95) >> 96;
            x = x - k * 54916777467707473351141471128;

            // k is in the range [-61, 195].

            // Evaluate using a (6, 7)-term rational approximation.
            // p is made monic, we'll multiply by a scale factor later.
            int256 y = x + 1346386616545796478920950773328;
            y = ((y * x) >> 96) + 57155421227552351082224309758442;
            int256 p = y + x - 94201549194550492254356042504812;
            p = ((p * y) >> 96) + 28719021644029726153956944680412240;
            p = p * x + (4385272521454847904659076985693276 << 96);

            // We leave p in 2**192 basis so we don't need to scale it back up for the division.
            int256 q = x - 2855989394907223263936484059900;
            q = ((q * x) >> 96) + 50020603652535783019961831881945;
            q = ((q * x) >> 96) - 533845033583426703283633433725380;
            q = ((q * x) >> 96) + 3604857256930695427073651918091429;
            q = ((q * x) >> 96) - 14423608567350463180887372962807573;
            q = ((q * x) >> 96) + 26449188498355588339934803723976023;

            assembly {
                // Div in assembly because solidity adds a zero check despite the unchecked.
                // The q polynomial won't have zeros in the domain as all its roots are complex.
                // No scaling is necessary because p is already 2**96 too large.
                r := sdiv(p, q)
            }

            // r should be in the range (0.09, 0.25) * 2**96.

            // We now need to multiply r by:
            // * the scale factor s = ~6.031367120.
            // * the 2**k factor from the range reduction.
            // * the 1e18 / 2**96 factor for base conversion.
            // We do this all at once, with an intermediate result in 2**213
            // basis, so the final right shift is always by a positive amount.
            r = int256((uint256(r) * 3822833074963236453042738258902158003155416615667) >> uint256(195 - k));
        }
    }

    function lnWad(int256 x) internal pure returns (int256 r) {
        unchecked {
            require(x > 0, "UNDEFINED");

            // We want to convert x from 10**18 fixed point to 2**96 fixed point.
            // We do this by multiplying by 2**96 / 10**18. But since
            // ln(x * C) = ln(x) + ln(C), we can simply do nothing here
            // and add ln(2**96 / 10**18) at the end.

            // Reduce range of x to (1, 2) * 2**96
            // ln(2^k * x) = k * ln(2) + ln(x)
            int256 k = int256(log2(uint256(x))) - 96;
            x <<= uint256(159 - k);
            x = int256(uint256(x) >> 159);

            // Evaluate using a (8, 8)-term rational approximation.
            // p is made monic, we will multiply by a scale factor later.
            int256 p = x + 3273285459638523848632254066296;
            p = ((p * x) >> 96) + 24828157081833163892658089445524;
            p = ((p * x) >> 96) + 43456485725739037958740375743393;
            p = ((p * x) >> 96) - 11111509109440967052023855526967;
            p = ((p * x) >> 96) - 45023709667254063763336534515857;
            p = ((p * x) >> 96) - 14706773417378608786704636184526;
            p = p * x - (795164235651350426258249787498 << 96);

            // We leave p in 2**192 basis so we don't need to scale it back up for the division.
            // q is monic by convention.
            int256 q = x + 5573035233440673466300451813936;
            q = ((q * x) >> 96) + 71694874799317883764090561454958;
            q = ((q * x) >> 96) + 283447036172924575727196451306956;
            q = ((q * x) >> 96) + 401686690394027663651624208769553;
            q = ((q * x) >> 96) + 204048457590392012362485061816622;
            q = ((q * x) >> 96) + 31853899698501571402653359427138;
            q = ((q * x) >> 96) + 909429971244387300277376558375;
            assembly {
                // Div in assembly because solidity adds a zero check despite the unchecked.
                // The q polynomial is known not to have zeros in the domain.
                // No scaling required because p is already 2**96 too large.
                r := sdiv(p, q)
            }

            // r is in the range (0, 0.125) * 2**96

            // Finalization, we need to:
            // * multiply by the scale factor s = 5.549…
            // * add ln(2**96 / 10**18)
            // * add k * ln(2)
            // * multiply by 10**18 / 2**96 = 5**18 >> 78

            // mul s * 5e18 * 2**96, base is now 5**18 * 2**192
            r *= 1677202110996718588342820967067443963516166;
            // add ln(2) * k * 5e18 * 2**192
            r += 16597577552685614221487285958193947469193820559219878177908093499208371 * k;
            // add ln(2**96 / 10**18) * 5e18 * 2**192
            r += 600920179829731861736702779321621459595472258049074101567377883020018308;
            // base conversion: mul 2**18 / 2**192
            r >>= 174;
        }
    }

    /*//////////////////////////////////////////////////////////////
                    LOW LEVEL FIXED POINT OPERATIONS
    //////////////////////////////////////////////////////////////*/

    function mulDivDown(
        uint256 x,
        uint256 y,
        uint256 denominator
    ) internal pure returns (uint256 z) {
        assembly {
            // Store x * y in z for now.
            z := mul(x, y)

            // Equivalent to require(denominator != 0 && (x == 0 || (x * y) / x == y))
            if iszero(and(iszero(iszero(denominator)), or(iszero(x), eq(div(z, x), y)))) {
                revert(0, 0)
            }

            // Divide z by the denominator.
            z := div(z, denominator)
        }
    }

    function mulDivUp(
        uint256 x,
        uint256 y,
        uint256 denominator
    ) internal pure returns (uint256 z) {
        assembly {
            // Store x * y in z for now.
            z := mul(x, y)

            // Equivalent to require(denominator != 0 && (x == 0 || (x * y) / x == y))
            if iszero(and(iszero(iszero(denominator)), or(iszero(x), eq(div(z, x), y)))) {
                revert(0, 0)
            }

            // First, divide z - 1 by the denominator and add 1.
            // We allow z - 1 to underflow if z is 0, because we multiply the
            // end result by 0 if z is zero, ensuring we return 0 if z is zero.
            z := mul(iszero(iszero(z)), add(div(sub(z, 1), denominator), 1))
        }
    }

    function rpow(
        uint256 x,
        uint256 n,
        uint256 scalar
    ) internal pure returns (uint256 z) {
        assembly {
            switch x
            case 0 {
                switch n
                case 0 {
                    // 0 ** 0 = 1
                    z := scalar
                }
                default {
                    // 0 ** n = 0
                    z := 0
                }
            }
            default {
                switch mod(n, 2)
                case 0 {
                    // If n is even, store scalar in z for now.
                    z := scalar
                }
                default {
                    // If n is odd, store x in z for now.
                    z := x
                }

                // Shifting right by 1 is like dividing by 2.
                let half := shr(1, scalar)

                for {
                    // Shift n right by 1 before looping to halve it.
                    n := shr(1, n)
                } n {
                    // Shift n right by 1 each iteration to halve it.
                    n := shr(1, n)
                } {
                    // Revert immediately if x ** 2 would overflow.
                    // Equivalent to iszero(eq(div(xx, x), x)) here.
                    if shr(128, x) {
                        revert(0, 0)
                    }

                    // Store x squared.
                    let xx := mul(x, x)

                    // Round to the nearest number.
                    let xxRound := add(xx, half)

                    // Revert if xx + half overflowed.
                    if lt(xxRound, xx) {
                        revert(0, 0)
                    }

                    // Set x to scaled xxRound.
                    x := div(xxRound, scalar)

                    // If n is even:
                    if mod(n, 2) {
                        // Compute z * x.
                        let zx := mul(z, x)

                        // If z * x overflowed:
                        if iszero(eq(div(zx, x), z)) {
                            // Revert if x is non-zero.
                            if iszero(iszero(x)) {
                                revert(0, 0)
                            }
                        }

                        // Round to the nearest number.
                        let zxRound := add(zx, half)

                        // Revert if zx + half overflowed.
                        if lt(zxRound, zx) {
                            revert(0, 0)
                        }

                        // Return properly scaled zxRound.
                        z := div(zxRound, scalar)
                    }
                }
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                        GENERAL NUMBER UTILITIES
    //////////////////////////////////////////////////////////////*/

    function sqrt(uint256 x) internal pure returns (uint256 z) {
        assembly {
            let y := x // We start y at x, which will help us make our initial estimate.

            z := 181 // The "correct" value is 1, but this saves a multiplication later.

            // This segment is to get a reasonable initial estimate for the Babylonian method. With a bad
            // start, the correct # of bits increases ~linearly each iteration instead of ~quadratically.

            // We check y >= 2^(k + 8) but shift right by k bits
            // each branch to ensure that if x >= 256, then y >= 256.
            if iszero(lt(y, 0x10000000000000000000000000000000000)) {
                y := shr(128, y)
                z := shl(64, z)
            }
            if iszero(lt(y, 0x1000000000000000000)) {
                y := shr(64, y)
                z := shl(32, z)
            }
            if iszero(lt(y, 0x10000000000)) {
                y := shr(32, y)
                z := shl(16, z)
            }
            if iszero(lt(y, 0x1000000)) {
                y := shr(16, y)
                z := shl(8, z)
            }

            // Goal was to get z*z*y within a small factor of x. More iterations could
            // get y in a tighter range. Currently, we will have y in [256, 256*2^16).
            // We ensured y >= 256 so that the relative difference between y and y+1 is small.
            // That's not possible if x < 256 but we can just verify those cases exhaustively.

            // Now, z*z*y <= x < z*z*(y+1), and y <= 2^(16+8), and either y >= 256, or x < 256.
            // Correctness can be checked exhaustively for x < 256, so we assume y >= 256.
            // Then z*sqrt(y) is within sqrt(257)/sqrt(256) of sqrt(x), or about 20bps.

            // For s in the range [1/256, 256], the estimate f(s) = (181/1024) * (s+1) is in the range
            // (1/2.84 * sqrt(s), 2.84 * sqrt(s)), with largest error when s = 1 and when s = 256 or 1/256.

            // Since y is in [256, 256*2^16), let a = y/65536, so that a is in [1/256, 256). Then we can estimate
            // sqrt(y) using sqrt(65536) * 181/1024 * (a + 1) = 181/4 * (y + 65536)/65536 = 181 * (y + 65536)/2^18.

            // There is no overflow risk here since y < 2^136 after the first branch above.
            z := shr(18, mul(z, add(y, 65536))) // A mul() is saved from starting z at 181.

            // Given the worst case multiplicative error of 2.84 above, 7 iterations should be enough.
            z := shr(1, add(z, div(x, z)))
            z := shr(1, add(z, div(x, z)))
            z := shr(1, add(z, div(x, z)))
            z := shr(1, add(z, div(x, z)))
            z := shr(1, add(z, div(x, z)))
            z := shr(1, add(z, div(x, z)))
            z := shr(1, add(z, div(x, z)))

            // If x+1 is a perfect square, the Babylonian method cycles between
            // floor(sqrt(x)) and ceil(sqrt(x)). This statement ensures we return floor.
            // See: https://en.wikipedia.org/wiki/Integer_square_root#Using_only_integer_division
            // Since the ceil is rare, we save gas on the assignment and repeat division in the rare case.
            // If you don't care whether the floor or ceil square root is returned, you can remove this statement.
            z := sub(z, lt(div(x, z), z))
        }
    }

    function log2(uint256 x) internal pure returns (uint256 r) {
        require(x > 0, "UNDEFINED");

        assembly {
            r := shl(7, lt(0xffffffffffffffffffffffffffffffff, x))
            r := or(r, shl(6, lt(0xffffffffffffffff, shr(r, x))))
            r := or(r, shl(5, lt(0xffffffff, shr(r, x))))
            r := or(r, shl(4, lt(0xffff, shr(r, x))))
            r := or(r, shl(3, lt(0xff, shr(r, x))))
            r := or(r, shl(2, lt(0xf, shr(r, x))))
            r := or(r, shl(1, lt(0x3, shr(r, x))))
            r := or(r, lt(0x1, shr(r, x)))
        }
    }
}

library Arithmetic {
    /// @notice Clamps a value between a minimum and maximum.
    /// @param _value The value to clamp.
    /// @param _min   The minimum value.
    /// @param _max   The maximum value.
    /// @return The clamped value.
    function clamp(int256 _value, int256 _min, int256 _max) internal pure returns (int256) {
        return SignedMath.min(SignedMath.max(_value, _min), _max);
    }

    /// @notice (c)oefficient (d)enominator (exp)onentiation function.
    ///         Returns the result of: c * (1 - 1/d)^exp.
    /// @param _coefficient Coefficient of the function.
    /// @param _denominator Fractional denominator.
    /// @param _exponent    Power function exponent.
    /// @return Result of c * (1 - 1/d)^exp.
    function cdexp(int256 _coefficient, int256 _denominator, int256 _exponent) internal pure returns (int256) {
        return (_coefficient * (FixedPointMathLib.powWad(1e18 - (1e18 / _denominator), _exponent * 1e18))) / 1e18;
    }
}

library Burn {
    /// @notice Burns a given amount of ETH.
    /// @param _amount Amount of ETH to burn.
    function eth(uint256 _amount) internal {
        new Burner{ value: _amount }();
    }

    /// @notice Burns a given amount of gas.
    /// @param _amount Amount of gas to burn.
    function gas(uint256 _amount) internal view {
        uint256 i = 0;
        uint256 initialGas = gasleft();
        while (initialGas - gasleft() < _amount) {
            ++i;
        }
    }
}

abstract contract ResourceMetering is Initializable {
    /// @notice Error returned when too much gas resource is consumed.
    error OutOfGas();

    /// @notice Represents the various parameters that control the way in which resources are
    ///         metered. Corresponds to the EIP-1559 resource metering system.
    /// @custom:field prevBaseFee   Base fee from the previous block(s).
    /// @custom:field prevBoughtGas Amount of gas bought so far in the current block.
    /// @custom:field prevBlockNum  Last block number that the base fee was updated.
    /// @custom:field prevTxCount  Number of transactions in the current block.
    struct ResourceParams {
        uint128 prevBaseFee;
        uint64 prevBoughtGas;
        uint64 prevBlockNum;
        uint16 prevTxCount;
    }

    /// @notice Represents the configuration for the EIP-1559 based curve for the deposit gas
    ///         market. These values should be set with care as it is possible to set them in
    ///         a way that breaks the deposit gas market. The target resource limit is defined as
    ///         maxResourceLimit / elasticityMultiplier. This struct was designed to fit within a
    ///         single word. There is additional space for additions in the future.
    /// @custom:field maxResourceLimit             Represents the maximum amount of deposit gas that
    ///                                            can be purchased per block.
    /// @custom:field elasticityMultiplier         Determines the target resource limit along with
    ///                                            the resource limit.
    /// @custom:field baseFeeMaxChangeDenominator  Determines max change on fee per block.
    /// @custom:field maxTransactionLimit          Determines max deposit transaction count per block.
    /// @custom:field minimumBaseFee               The min deposit base fee, it is clamped to this
    ///                                            value.
    /// @custom:field systemTxMaxGas               The amount of gas supplied to the system
    ///                                            transaction. This should be set to the same
    ///                                            number that the op-node sets as the gas limit
    ///                                            for the system transaction.
    /// @custom:field maximumBaseFee               The max deposit base fee, it is clamped to this
    ///                                            value.
    struct ResourceConfig {
        uint32 maxResourceLimit;
        uint8 elasticityMultiplier;
        uint8 baseFeeMaxChangeDenominator;
        uint16 maxTransactionLimit;
        uint32 minimumBaseFee;
        uint32 systemTxMaxGas;
        uint128 maximumBaseFee;
    }

    /// @notice EIP-1559 style gas parameters.
    ResourceParams public params;

    /// @notice Reserve extra slots (to a total of 50) in the storage layout for future upgrades.
    uint256[48] private __gap;

    event GasBurned(uint256 gasAmount, address indexed sender);

    /// @notice Meters access to a function based an amount of a requested resource.
    /// @param _amount Amount of the resource requested.
    modifier metered(uint64 _amount) {
        // Record initial gas amount so we can refund for it later.
        uint256 initialGas = gasleft();

        // Run the underlying function.
        _;

        // Run the metering function.
        _metered(_amount, initialGas);
    }

    /// @notice An internal function that holds all of the logic for metering a resource.
    /// @param _amount     Amount of the resource requested.
    /// @param _initialGas The amount of gas before any modifier execution.
    function _metered(uint64 _amount, uint256 _initialGas) internal {
        // Update block number and base fee if necessary.
        uint256 blockDiff = block.number - params.prevBlockNum;

        ResourceConfig memory config = _resourceConfig();
        int256 targetResourceLimit =
            int256(uint256(config.maxResourceLimit)) / int256(uint256(config.elasticityMultiplier));

        if (blockDiff > 0) {
            // Handle updating EIP-1559 style gas parameters. We use EIP-1559 to restrict the rate
            // at which deposits can be created and therefore limit the potential for deposits to
            // spam the L2 system. Fee scheme is very similar to EIP-1559 with minor changes.

            // If limit deposit limit is hit, increase the gas fee by max amount
            uint256 boughtGas = params.prevBoughtGas;
            if (params.prevTxCount == config.maxTransactionLimit) {
                boughtGas = Math.max(uint256(targetResourceLimit * 2), boughtGas);
            }
            int256 gasUsedDelta = int256(boughtGas) - targetResourceLimit;
            int256 baseFeeDelta = (int256(uint256(params.prevBaseFee)) * gasUsedDelta)
                / (targetResourceLimit * int256(uint256(config.baseFeeMaxChangeDenominator)));

            // Update base fee by adding the base fee delta and clamp the resulting value between
            // min and max.
            int256 newBaseFee = Arithmetic.clamp({
                _value: int256(uint256(params.prevBaseFee)) + baseFeeDelta,
                _min: int256(uint256(config.minimumBaseFee)),
                _max: int256(uint256(config.maximumBaseFee))
            });

            // If we skipped more than one block, we also need to account for every empty block.
            // Empty block means there was no demand for deposits in that block, so we should
            // reflect this lack of demand in the fee.
            if (blockDiff > 1) {
                // Update the base fee by repeatedly applying the exponent 1-(1/change_denominator)
                // blockDiff - 1 times. Simulates multiple empty blocks. Clamp the resulting value
                // between min and max.
                newBaseFee = Arithmetic.clamp({
                    _value: Arithmetic.cdexp({
                        _coefficient: newBaseFee,
                        _denominator: int256(uint256(config.baseFeeMaxChangeDenominator)),
                        _exponent: int256(blockDiff - 1)
                    }),
                    _min: int256(uint256(config.minimumBaseFee)),
                    _max: int256(uint256(config.maximumBaseFee))
                });
            }

            // Update new base fee, reset bought gas, and update block number.
            params.prevBaseFee = uint128(uint256(newBaseFee));
            params.prevBoughtGas = 0;
            params.prevTxCount = 0;
            params.prevBlockNum = uint64(block.number);
        }

        params.prevTxCount += 1;
        // If limit is surpassed,
        require(params.prevTxCount <= config.maxTransactionLimit, "ResourceMetering: too many deposits in this block");

        // Make sure we can actually buy the resource amount requested by the user.
        params.prevBoughtGas += _amount;
        if (int256(uint256(params.prevBoughtGas)) > int256(uint256(config.maxResourceLimit))) {
            revert OutOfGas();
        }

        // Determine the amount of ETH to be paid.
        uint256 resourceCost = uint256(_amount) * uint256(params.prevBaseFee);

        // We currently charge for this ETH amount as an L1 gas burn, so we convert the ETH amount
        // into gas by dividing by the L1 base fee. We assume a minimum base fee of 1 gwei to avoid
        // division by zero for L1s that don't support 1559 or to avoid excessive gas burns during
        // periods of extremely low L1 demand. One-day average gas fee hasn't dipped below 1 gwei
        // during any 1 day period in the last 5 years, so should be fine.
        uint256 gasCost = resourceCost / Math.max(block.basefee, 1 gwei);

        // Give the user a refund based on the amount of gas they used to do all of the work up to
        // this point. Since we're at the end of the modifier, this should be pretty accurate. Acts
        // effectively like a dynamic stipend (with a minimum value).
        uint256 usedGas = _initialGas - gasleft();
        if (gasCost > usedGas) {
            // We calculate gasToBurn based on the resourceCosts, but reserve some Gas for an event
            // that keeps track of the GasBurned. There we add the costs for the event because we
            // would be burning it otherwise
            uint256 gasToBurn = gasCost - usedGas;
            // Gas Costs For Event:
            // 375 Per LOG* operation.
            // 375 per indexed parameter
            // 8   Per byte in a LOG* operation's data.
            // 375 + 375 + 256 + 160 = 1166 (uint256 32 bytes, address 20bytes)
            uint256 estimatedEventGasCosts = 1200;

            // Ensure gasToBurn is greater than estimatedEventGasCosts to avoid underflow
            if (gasToBurn > estimatedEventGasCosts) {
                emit GasBurned(gasToBurn - estimatedEventGasCosts, tx.origin);
                // Subtract estimatedEventGasCosts because the event emission accounts for this already
                Burn.gas(gasToBurn - estimatedEventGasCosts);
            } else {
                // Handle case where gasToBurn is not enough to cover estimatedEventGasCosts
                // Emit event with what we have and burn zero gas
                emit GasBurned(estimatedEventGasCosts, tx.origin);
                Burn.gas(0);
            }
        }
    }

    /// @notice Virtual function that returns the resource config.
    ///         Contracts that inherit this contract must implement this function.
    /// @return ResourceConfig
    function _resourceConfig() internal virtual returns (ResourceConfig memory);

    /// @notice Sets initial resource parameter values.
    ///         This function must either be called by the initializer function of an upgradeable
    ///         child contract.
    // solhint-disable-next-line func-name-mixedcase
    function __ResourceMetering_init() internal onlyInitializing {
        if (params.prevBlockNum == 0) {
            params = ResourceParams({ prevBaseFee: 1 gwei, prevBoughtGas: 0, prevBlockNum: uint64(block.number), prevTxCount: 0 });
        }
    }
}

abstract contract Initializable {
    /**
     * @dev Storage of the initializable contract.
     *
     * It's implemented on a custom ERC-7201 namespace to reduce the risk of storage collisions
     * when using with upgradeable contracts.
     *
     * @custom:storage-location erc7201:openzeppelin.storage.Initializable
     */
    struct InitializableStorage {
        /**
         * @dev Indicates that the contract has been initialized.
         */
        uint64 _initialized;
        /**
         * @dev Indicates that the contract is in the process of being initialized.
         */
        bool _initializing;
    }

    // keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.Initializable")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant INITIALIZABLE_STORAGE = 0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;

    /**
     * @dev The contract is already initialized.
     */
    error InvalidInitialization();

    /**
     * @dev The contract is not initializing.
     */
    error NotInitializing();

    /**
     * @dev Triggered when the contract has been initialized or reinitialized.
     */
    event Initialized(uint64 version);

    /**
     * @dev A modifier that defines a protected initializer function that can be invoked at most once. In its scope,
     * `onlyInitializing` functions can be used to initialize parent contracts.
     *
     * Similar to `reinitializer(1)`, except that in the context of a constructor an `initializer` may be invoked any
     * number of times. This behavior in the constructor can be useful during testing and is not expected to be used in
     * production.
     *
     * Emits an {Initialized} event.
     */
    modifier initializer() {
        // solhint-disable-next-line var-name-mixedcase
        InitializableStorage storage $ = _getInitializableStorage();

        // Cache values to avoid duplicated sloads
        bool isTopLevelCall = !$._initializing;
        uint64 initialized = $._initialized;

        // Allowed calls:
        // - initialSetup: the contract is not in the initializing state and no previous version was
        //                 initialized
        // - construction: the contract is initialized at version 1 (no reininitialization) and the
        //                 current contract is just being deployed
        bool initialSetup = initialized == 0 && isTopLevelCall;
        bool construction = initialized == 1 && address(this).code.length == 0;

        if (!initialSetup && !construction) {
            revert InvalidInitialization();
        }
        $._initialized = 1;
        if (isTopLevelCall) {
            $._initializing = true;
        }
        _;
        if (isTopLevelCall) {
            $._initializing = false;
            emit Initialized(1);
        }
    }

    /**
     * @dev A modifier that defines a protected reinitializer function that can be invoked at most once, and only if the
     * contract hasn't been initialized to a greater version before. In its scope, `onlyInitializing` functions can be
     * used to initialize parent contracts.
     *
     * A reinitializer may be used after the original initialization step. This is essential to configure modules that
     * are added through upgrades and that require initialization.
     *
     * When `version` is 1, this modifier is similar to `initializer`, except that functions marked with `reinitializer`
     * cannot be nested. If one is invoked in the context of another, execution will revert.
     *
     * Note that versions can jump in increments greater than 1; this implies that if multiple reinitializers coexist in
     * a contract, executing them in the right order is up to the developer or operator.
     *
     * WARNING: Setting the version to 2**64 - 1 will prevent any future reinitialization.
     *
     * Emits an {Initialized} event.
     */
    modifier reinitializer(uint64 version) {
        // solhint-disable-next-line var-name-mixedcase
        InitializableStorage storage $ = _getInitializableStorage();

        if ($._initializing || $._initialized >= version) {
            revert InvalidInitialization();
        }
        $._initialized = version;
        $._initializing = true;
        _;
        $._initializing = false;
        emit Initialized(version);
    }

    /**
     * @dev Modifier to protect an initialization function so that it can only be invoked by functions with the
     * {initializer} and {reinitializer} modifiers, directly or indirectly.
     */
    modifier onlyInitializing() {
        _checkInitializing();
        _;
    }

    /**
     * @dev Reverts if the contract is not in an initializing state. See {onlyInitializing}.
     */
    function _checkInitializing() internal view virtual {
        if (!_isInitializing()) {
            revert NotInitializing();
        }
    }

    /**
     * @dev Locks the contract, preventing any future reinitialization. This cannot be part of an initializer call.
     * Calling this in the constructor of a contract will prevent that contract from being initialized or reinitialized
     * to any version. It is recommended to use this to lock implementation contracts that are designed to be called
     * through proxies.
     *
     * Emits an {Initialized} event the first time it is successfully executed.
     */
    function _disableInitializers() internal virtual {
        // solhint-disable-next-line var-name-mixedcase
        InitializableStorage storage $ = _getInitializableStorage();

        if ($._initializing) {
            revert InvalidInitialization();
        }
        if ($._initialized != type(uint64).max) {
            $._initialized = type(uint64).max;
            emit Initialized(type(uint64).max);
        }
    }

    /**
     * @dev Returns the highest version that has been initialized. See {reinitializer}.
     */
    function _getInitializedVersion() internal view returns (uint64) {
        return _getInitializableStorage()._initialized;
    }

    /**
     * @dev Returns `true` if the contract is currently initializing. See {onlyInitializing}.
     */
    function _isInitializing() internal view returns (bool) {
        return _getInitializableStorage()._initializing;
    }

    /**
     * @dev Returns a pointer to the storage namespace.
     */
    // solhint-disable-next-line var-name-mixedcase
    function _getInitializableStorage() private pure returns (InitializableStorage storage $) {
        assembly {
            $.slot := INITIALIZABLE_STORAGE
        }
    }
}

contract OptimismPortal is Initializable, ResourceMetering, ISemver {
    /// @notice Represents a proven withdrawal.
    /// @custom:field outputRoot    Root of the L2 output this was proven against.
    /// @custom:field timestamp     Timestamp at which the withdrawal was proven.
    /// @custom:field l2OutputIndex Index of the output this was proven against.
    struct ProvenWithdrawal {
        bytes32 outputRoot;
        uint128 timestamp;
        uint128 l2OutputIndex;
    }

    /// @notice Version of the deposit event.
    uint256 internal constant DEPOSIT_VERSION = 0;

    /// @notice The L2 gas limit set when eth is deposited using the receive() function.
    uint64 internal constant RECEIVE_DEFAULT_GAS_LIMIT = 100_000;

    /// @notice Address of the L2 account which initiated a withdrawal in this transaction.
    ///         If the of this variable is the default L2 sender address, then we are NOT inside of
    ///         a call to finalizeWithdrawalTransaction.
    address public l2Sender;

    /// @notice A list of withdrawal hashes which have been successfully finalized.
    mapping(bytes32 => bool) public finalizedWithdrawals;

    /// @notice Mapping of withdrawal hashes to `ProvenWithdrawal` data
    mapping(bytes32 => ProvenWithdrawal) public provenWithdrawals;

    /// @notice The address of the Superchain Config contract.
    SuperchainConfig public superchainConfig;

    uint256[24] spacer_54_0_768;

    /// @notice Contract of the L2OutputOracle.
    /// @custom:network-specific
    L2OutputOracle public l2Oracle;

    /// @notice Contract of the SystemConfig.
    /// @custom:network-specific
    SystemConfig public systemConfig;

    /// @notice Emitted when a transaction is deposited from L1 to L2.
    ///         The parameters of this event are read by the rollup node and used to derive deposit
    ///         transactions on L2.
    /// @param from       Address that triggered the deposit transaction.
    /// @param to         Address that the deposit transaction is directed to.
    /// @param version    Version of this deposit transaction event.
    /// @param opaqueData ABI encoded deposit data to be parsed off-chain.
    event TransactionDeposited(address indexed from, address indexed to, uint256 indexed version, bytes opaqueData);

    /// @notice Legacy, removed but kept for backwards compatibility in the bindings
    /// @notice Emitted when a withdrawal transaction is proven.
    /// @param withdrawalHash Hash of the withdrawal transaction.
    /// @param from           Address that triggered the withdrawal transaction.
    /// @param to             Address that the withdrawal transaction is directed to.
    event WithdrawalProven(bytes32 indexed withdrawalHash, address indexed from, address indexed to);

    /// @notice Emitted when a withdrawal transaction is finalized.
    /// @param withdrawalHash Hash of the withdrawal transaction.
    /// @param success        Whether the withdrawal transaction was successful.
    event WithdrawalFinalized(bytes32 indexed withdrawalHash, bool success);

    /// @notice Reverts when paused.
    modifier whenNotPaused() {
        require(paused() == false, "OptimismPortal: paused");
        _;
    }

    /// @notice Semantic version.
    /// @custom:semver 2.0.2
    string public constant version = "2.0.2";

    /// @notice Constructs the OptimismPortal contract.
    constructor() {
        initialize({
            _l2Oracle: L2OutputOracle(address(0)),
            _systemConfig: SystemConfig(address(0)),
            _superchainConfig: SuperchainConfig(address(0))
        });
    }

    /// @notice Initializer.
    /// @param _l2Oracle Contract of the L2OutputOracle.
    /// @param _systemConfig Contract of the SystemConfig.
    /// @param _superchainConfig Contract of the SuperchainConfig.
    function initialize(
        L2OutputOracle _l2Oracle,
        SystemConfig _systemConfig,
        SuperchainConfig _superchainConfig
    )
        public
        initializer
    {
        l2Oracle = _l2Oracle;
        systemConfig = _systemConfig;
        superchainConfig = _superchainConfig;
        if (l2Sender == address(0)) {
            l2Sender = Constants.DEFAULT_L2_SENDER;
        }
        __ResourceMetering_init();
    }

    /// @notice Getter function for the address of the guardian. This will be removed in the future, use
    /// `SuperchainConfig.guardian()` instead.
    /// @notice Address of the guardian.
    /// @custom:legacy
    function guardian() public view returns (address) {
        return superchainConfig.guardian();
    }

    /// @notice Getter for the current paused status.
    function paused() public view returns (bool paused_) {
        paused_ = superchainConfig.paused();
    }

    /// @notice Computes the minimum gas limit for a deposit.
    ///         The minimum gas limit linearly increases based on the size of the calldata.
    ///         This is to prevent users from creating L2 resource usage without paying for it.
    ///         This function can be used when interacting with the portal to ensure forwards
    ///         compatibility.
    /// @param _byteCount Number of bytes in the calldata.
    /// @return The minimum gas limit for a deposit.
    function minimumGasLimit(uint64 _byteCount) public pure returns (uint64) {
        return _byteCount * 16 + 21000;
    }

    /// @notice Accepts value so that users can send ETH directly to this contract and have the
    ///         funds be deposited to their address on L2. This is intended as a convenience
    ///         function for EOAs. Contracts should call the depositTransaction() function directly
    ///         otherwise any deposited funds will be lost due to address aliasing.
    // solhint-disable-next-line ordering
    receive() external payable {
        depositTransaction(msg.sender, msg.value, RECEIVE_DEFAULT_GAS_LIMIT, false, bytes(""));
    }

    /// @notice Accepts ETH value without triggering a deposit to L2.
    ///         This function mainly exists for the sake of the migration between the legacy
    ///         Optimism system and Bedrock.
    function donateETH() external payable {
        // Intentionally empty.
    }

    /// @notice Getter for the resource config.
    ///         Used internally by the ResourceMetering contract.
    ///         The SystemConfig is the source of truth for the resource config.
    /// @return ResourceMetering ResourceConfig
    function _resourceConfig() internal view override returns (ResourceMetering.ResourceConfig memory) {
        return systemConfig.resourceConfig();
    }


    /// @notice Proves and finalizes a withdrawal transaction.
    /// @param _tx              Withdrawal transaction to finalize.
    /// @param _l2OutputIndex   L2 output index to prove against.
    /// @param _outputRootProof Inclusion proof of the L2ToL1MessagePasser contract's storage root.
    /// @param _withdrawalProof Inclusion proof of the withdrawal in L2ToL1MessagePasser contract.
    function proveWithdrawalTransaction(
        Types.WithdrawalTransaction memory _tx,
        uint256 _l2OutputIndex,
        Types.OutputRootProof calldata _outputRootProof,
        bytes[] calldata _withdrawalProof
    )
        external
        whenNotPaused
    {
        // Prevent users from creating a deposit transaction where this address is the message
        // sender on L2
        require(_tx.target != address(this), "OptimismPortal: you cannot send messages to the portal contract");

        // Make sure that the l2Sender has not yet been set. The l2Sender is set to a value other
        // than the default value when a withdrawal transaction is being finalized. This check is
        // a defacto reentrancy guard.
        require(
            l2Sender == Constants.DEFAULT_L2_SENDER, "OptimismPortal: can only trigger one withdrawal per transaction"
        );

        // Get the output root and finalization time. This will revert if there is no output root for the given block number.
        (bytes32 outputRoot, uint256 outputFinalizedAt) = l2Oracle.getL2OutputRootWithFinalization(_l2OutputIndex);

        // Verify that the output root can be generated with the elements in the proof.
        require(
            outputRoot == Hashing.hashOutputRootProof(_outputRootProof), "OptimismPortal: invalid output root proof"
        );

        // Load the ProvenWithdrawal into memory, using the withdrawal hash as a unique identifier.
        bytes32 withdrawalHash = Hashing.hashWithdrawal(_tx);

        // Compute the storage slot of the withdrawal hash in the L2ToL1MessagePasser contract.
        // Refer to the Solidity documentation for more information on how storage layouts are
        // computed for mappings.
        bytes32 storageKey = keccak256(
            abi.encode(
                withdrawalHash,
                uint256(0) // The withdrawals mapping is at the first slot in the layout.
            )
        );

        // Verify that the hash of this withdrawal was stored in the L2toL1MessagePasser contract
        // on L2. If this is true, under the assumption that the SecureMerkleTrie does not have
        // bugs, then we know that this withdrawal was actually triggered on L2 and can therefore
        // be relayed on L1.
        require(
            SecureMerkleTrie.verifyInclusionProof(
                abi.encode(storageKey), hex"01", _withdrawalProof, _outputRootProof.messagePasserStorageRoot
            ),
            "OptimismPortal: invalid withdrawal inclusion proof"
        );

        // A withdrawal must wait at least the finalization period before it can be finalized.
        require(
            block.timestamp >= outputFinalizedAt,
            "OptimismPortal: proven withdrawal finalization period has not elapsed"
        );

        // Check that this withdrawal has not already been finalized, this is replay protection.
        require(finalizedWithdrawals[withdrawalHash] == false, "OptimismPortal: withdrawal has already been finalized");

        // Mark the withdrawal as finalized so it can't be replayed.
        finalizedWithdrawals[withdrawalHash] = true;

        // Set the l2Sender so contracts know who triggered this withdrawal on L2.
        l2Sender = _tx.sender;

        // Trigger the call to the target contract. We use a custom low level method
        // SafeCall.callWithMinGas to ensure two key properties
        //   1. Target contracts cannot force this call to run out of gas by returning a very large
        //      amount of data (and this is OK because we don't care about the returndata here).
        //   2. The amount of gas provided to the execution context of the target is at least the
        //      gas limit specified by the user. If there is not enough gas in the current context
        //      to accomplish this, `callWithMinGas` will revert.
        bool success = SafeCall.callWithMinGas(_tx.target, _tx.gasLimit, _tx.value, _tx.data);

        // Reset the l2Sender back to the default value.
        l2Sender = Constants.DEFAULT_L2_SENDER;

        // All withdrawals are immediately finalized. Replayability can
        // be achieved through contracts built on top of this contract
        emit WithdrawalFinalized(withdrawalHash, success);

        // Reverting here is useful for determining the exact gas cost to successfully execute the
        // sub call to the target contract if the minimum gas limit specified by the user would not
        // be sufficient to execute the sub call.
        if (success == false && tx.origin == Constants.ESTIMATION_ADDRESS) {
            revert("OptimismPortal: withdrawal failed");
        }
    }

    /// @notice Finalizes a withdrawal transaction. Keeping this function for legacy transactions that
    ///         were proven before the single step withdrawal process was introduced.
    /// @param _tx Withdrawal transaction to finalize.
    function finalizeWithdrawalTransaction(Types.WithdrawalTransaction memory _tx) external whenNotPaused {
        // Make sure that the l2Sender has not yet been set. The l2Sender is set to a value other
        // than the default value when a withdrawal transaction is being finalized. This check is
        // a defacto reentrancy guard.
        require(
            l2Sender == Constants.DEFAULT_L2_SENDER, "OptimismPortal: can only trigger one withdrawal per transaction"
        );

        // Grab the proven withdrawal from the `provenWithdrawals` map.
        bytes32 withdrawalHash = Hashing.hashWithdrawal(_tx);
        ProvenWithdrawal memory provenWithdrawal = provenWithdrawals[withdrawalHash];

        // A withdrawal can only be finalized if it has been proven. We know that a withdrawal has
        // been proven at least once when its timestamp is non-zero. Unproven withdrawals will have
        // a timestamp of zero.
        require(provenWithdrawal.timestamp != 0, "OptimismPortal: withdrawal has not been proven yet");

        // As a sanity check, we make sure that the proven withdrawal's timestamp is greater than
        // starting timestamp inside the L2OutputOracle. Not strictly necessary but extra layer of
        // safety against weird bugs in the proving step.
        require(
            provenWithdrawal.timestamp >= l2Oracle.startingTimestamp(),
            "OptimismPortal: withdrawal timestamp less than L2 Oracle starting timestamp"
        );

        // Get the output root and finalization time. This will revert if there is no output root for the given block number.
        (bytes32 outputRoot, uint256 outputFinalizedAt) = l2Oracle.getL2OutputRootWithFinalization(provenWithdrawal.l2OutputIndex);

        // A proven withdrawal must wait at least the finalization period before it can be
        // finalized. This waiting period can elapse in parallel with the waiting period for the
        // output the withdrawal was proven against. In effect, this means that the minimum
        // withdrawal time is proposal submission time + finalization period.
        require(
            block.timestamp >= outputFinalizedAt,
            "OptimismPortal: proven withdrawal finalization period has not elapsed"
        );

        // Check that the output root that was used to prove the withdrawal is the same as the
        // current output root for the given output index. An output root may change if it is
        // deleted by the challenger address and then re-proposed.
        require(
            outputRoot == provenWithdrawal.outputRoot,
            "OptimismPortal: output root proven is not the same as current output root"
        );

        // Check that this withdrawal has not already been finalized, this is replay protection.
        require(finalizedWithdrawals[withdrawalHash] == false, "OptimismPortal: withdrawal has already been finalized");

        // Mark the withdrawal as finalized so it can't be replayed.
        finalizedWithdrawals[withdrawalHash] = true;

        // Set the l2Sender so contracts know who triggered this withdrawal on L2.
        l2Sender = _tx.sender;

        // Trigger the call to the target contract. We use a custom low level method
        // SafeCall.callWithMinGas to ensure two key properties
        //   1. Target contracts cannot force this call to run out of gas by returning a very large
        //      amount of data (and this is OK because we don't care about the returndata here).
        //   2. The amount of gas provided to the execution context of the target is at least the
        //      gas limit specified by the user. If there is not enough gas in the current context
        //      to accomplish this, `callWithMinGas` will revert.
        bool success = SafeCall.callWithMinGas(_tx.target, _tx.gasLimit, _tx.value, _tx.data);

        // Reset the l2Sender back to the default value.
        l2Sender = Constants.DEFAULT_L2_SENDER;

        // All withdrawals are immediately finalized. Replayability can
        // be achieved through contracts built on top of this contract
        emit WithdrawalFinalized(withdrawalHash, success);

        // Reverting here is useful for determining the exact gas cost to successfully execute the
        // sub call to the target contract if the minimum gas limit specified by the user would not
        // be sufficient to execute the sub call.
        if (success == false && tx.origin == Constants.ESTIMATION_ADDRESS) {
            revert("OptimismPortal: withdrawal failed");
        }
    }

    /// @notice Accepts deposits of ETH and data, and emits a TransactionDeposited event for use in
    ///         deriving deposit transactions. Note that if a deposit is made by a contract, its
    ///         address will be aliased when retrieved using `tx.origin` or `msg.sender`. Consider
    ///         using the CrossDomainMessenger contracts for a simpler developer experience.
    /// @param _to         Target address on L2.
    /// @param _value      ETH value to send to the recipient.
    /// @param _gasLimit   Amount of L2 gas to purchase by burning gas on L1.
    /// @param _isCreation Whether or not the transaction is a contract creation.
    /// @param _data       Data to trigger the recipient with.
    function depositTransaction(
        address _to,
        uint256 _value,
        uint64 _gasLimit,
        bool _isCreation,
        bytes memory _data
    )
        public
        payable
        whenNotPaused
        metered(_gasLimit)
    {
        // Just to be safe, make sure that people specify address(0) as the target when doing
        // contract creations.
        if (_isCreation) {
            require(_to == address(0), "OptimismPortal: must send to address(0) when creating a contract");
        }

        // Prevent depositing transactions that have too small of a gas limit. Users should pay
        // more for more resource usage.
        require(_gasLimit >= minimumGasLimit(uint64(_data.length)), "OptimismPortal: gas limit too small");

        // Prevent the creation of deposit transactions that have too much calldata. This gives an
        // upper limit on the size of unsafe blocks over the p2p network. 120kb is chosen to ensure
        // that the transaction can fit into the p2p network policy of 128kb even though deposit
        // transactions are not gossipped over the p2p network.
        require(_data.length <= 120_000, "OptimismPortal: data too large");

        // Transform the from-address to its alias if the caller is a contract.
        address from = msg.sender;
        if (msg.sender != tx.origin) {
            from = AddressAliasHelper.applyL1ToL2Alias(msg.sender);
        }

        // Compute the opaque data that will be emitted as part of the TransactionDeposited event.
        // We use opaque data so that we can update the TransactionDeposited event in the future
        // without breaking the current interface.
        bytes memory opaqueData = abi.encodePacked(msg.value, _value, _gasLimit, _isCreation, _data);

        // Emit a TransactionDeposited event so that the rollup node can derive a deposit
        // transaction for this deposit.
        emit TransactionDeposited(from, _to, DEPOSIT_VERSION, opaqueData);
    }

    /// @notice Determine if a given output is finalized.
    ///         Reverts if the call to l2Oracle.getL2Output reverts.
    ///         Returns a boolean otherwise.
    /// @param _l2OutputIndex Index of the L2 output to check.
    /// @return Whether or not the output is finalized.
    function isOutputFinalized(uint256 _l2OutputIndex) external view returns (bool) {
        (, uint256 outputFinalizedAt) = l2Oracle.getL2OutputRootWithFinalization(_l2OutputIndex);
        return block.timestamp >= outputFinalizedAt;
    }
}