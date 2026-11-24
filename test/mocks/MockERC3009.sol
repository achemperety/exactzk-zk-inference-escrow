// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// ERC-20 with ERC-3009 `receiveWithAuthorization` (bytes-signature form), checking signatures the
/// way USDC v2.2 does: ECDSA if the signer has no code, ERC-1271 if it has. Unit tests only; gas
/// differs from USDC (no proxy, no pause or blacklist checks, a fixed domain separator).
contract MockERC3009 {
    bytes32 public constant RECEIVE_WITH_AUTHORIZATION_TYPEHASH = keccak256(
        "ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );
    // Upper bound for `s` in a non-malleable ECDSA signature (secp256k1 order / 2).
    uint256 private constant S_MAX = 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0;

    bytes32 public immutable DOMAIN_SEPARATOR;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(bytes32 => bool)) public authorizationState;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event AuthorizationUsed(address indexed authorizer, bytes32 indexed nonce);

    constructor() {
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("USD Coin"),
                keccak256("2"),
                block.chainid,
                address(this)
            )
        );
    }

    function mint(address to, uint256 value) external {
        balanceOf[to] += value;
        emit Transfer(address(0), to, value);
    }

    function transfer(address to, uint256 value) public virtual returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata signature
    ) external {
        require(to == msg.sender, "caller must be the payee");
        require(block.timestamp > validAfter, "authorization is not yet valid");
        require(block.timestamp < validBefore, "authorization is expired");
        require(!authorizationState[from][nonce], "authorization is used or canceled");
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                DOMAIN_SEPARATOR,
                keccak256(
                    abi.encode(RECEIVE_WITH_AUTHORIZATION_TYPEHASH, from, to, value, validAfter, validBefore, nonce)
                )
            )
        );
        require(_isValidSignatureNow(from, digest, signature), "invalid signature");
        authorizationState[from][nonce] = true;
        emit AuthorizationUsed(from, nonce);
        _transfer(from, to, value);
    }

    function digestFor(address from, address to, uint256 value, uint256 validBefore, bytes32 nonce)
        external
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encodePacked(
                "\x19\x01",
                DOMAIN_SEPARATOR,
                keccak256(abi.encode(RECEIVE_WITH_AUTHORIZATION_TYPEHASH, from, to, value, 0, validBefore, nonce))
            )
        );
    }

    function _transfer(address from, address to, uint256 value) internal {
        require(to != address(0), "transfer to the zero address");
        require(balanceOf[from] >= value, "transfer amount exceeds balance");
        balanceOf[from] -= value;
        balanceOf[to] += value;
        emit Transfer(from, to, value);
    }

    function _isValidSignatureNow(address signer, bytes32 digest, bytes calldata signature)
        private
        view
        returns (bool)
    {
        if (signer.code.length == 0) {
            require(signature.length == 65, "invalid signature length");
            bytes32 r = bytes32(signature[0:32]);
            bytes32 s = bytes32(signature[32:64]);
            uint8 v = uint8(signature[64]);
            require(uint256(s) <= S_MAX, "invalid signature 's' value");
            require(v == 27 || v == 28, "invalid signature 'v' value");
            address recovered = ecrecover(digest, v, r, s);
            require(recovered != address(0), "invalid signature");
            return recovered == signer;
        }
        (bool ok, bytes memory ret) =
            signer.staticcall(abi.encodeWithSelector(IERC1271.isValidSignature.selector, digest, signature));
        return ok && ret.length >= 32 && abi.decode(ret, (bytes4)) == IERC1271.isValidSignature.selector;
    }
}

interface IERC1271 {
    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4);
}

/// A contract account whose signatures are its owner's ECDSA signatures. `accepting` can be turned
/// off to make it reject everything.
contract MockSmartWallet is IERC1271 {
    address public immutable owner;
    bool public accepting = true;

    constructor(address owner_) {
        owner = owner_;
    }

    function setAccepting(bool value) external {
        accepting = value;
    }

    /// The owner makes the wallet call `target`, as a smart account executes a user operation.
    function execute(address target, bytes calldata data) external returns (bytes memory) {
        require(msg.sender == owner, "not owner");
        (bool ok, bytes memory ret) = target.call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        return ret;
    }

    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        if (!accepting || signature.length != 65) return 0xffffffff;
        address signer = ecrecover(hash, uint8(signature[64]), bytes32(signature[0:32]), bytes32(signature[32:64]));
        return signer == owner && signer != address(0) ? IERC1271.isValidSignature.selector : bytes4(0xffffffff);
    }
}

/// A token whose `transfer` reports failure by returning `false` instead of reverting.
contract FalseReturningERC3009 is MockERC3009 {
    function transfer(address, uint256) public pure override returns (bool) {
        return false;
    }
}

/// A token that, while armed, calls back into a target from inside `transfer` once, and records
/// whether that inner call succeeded. Used to show that settlement writes its state before paying.
contract ReentrantERC3009 is MockERC3009 {
    address public target;
    bytes public payload;
    bool public armed;
    bool public reentered;
    bool public innerCallSucceeded;

    function arm(address target_, bytes calldata payload_) external {
        target = target_;
        payload = payload_;
        armed = true;
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        if (armed) {
            armed = false;
            reentered = true;
            (innerCallSucceeded,) = target.call(payload);
        }
        return super.transfer(to, value);
    }
}
