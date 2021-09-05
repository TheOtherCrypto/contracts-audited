// SPDX-License-Identifier: MIT
/**
Very similar to the polyzap one and all the others based on Uniswap V2

Contains an additional _owner that lets us change the feeAmount.
That's important because initially we need to leverage the moneypot for shareholders.
When we gain shares in the AMM space, we will also consider reducing the portion for the moneypot
once all becames sustainable through deposit fees.

Non-standard function --> setFeeAmount and feeAmount
 */
pragma solidity >= 0.5.16;

import "./interfaces/IProtofiFactory.sol";
import "./ProtofiPair.sol";

contract ProtofiFactory is IProtofiFactory {
    bytes32 public constant INIT_CODE_PAIR_HASH = keccak256(abi.encodePacked(type(ProtofiPair).creationCode));

    address public feeTo;
    address public feeToSetter;
    address private _owner;
    uint16 private _feeAmount;

    mapping(address => mapping(address => address)) public getPair;
    address[] public allPairs;

    event PairCreated(address indexed token0, address indexed token1, address pair, uint);

    constructor(address _feeTo, address owner, uint16 _feePercent) public {
        feeToSetter = owner;
        feeTo = _feeTo;
        _owner = owner;
        _feeAmount = _feePercent;
    }

    function owner() public view returns (address) {
        return _owner;
    }

    function allPairsLength() external view returns (uint) {
        return allPairs.length;
    }

    function createPair(address tokenA, address tokenB) external returns (address pair) {
        require(tokenA != tokenB, 'Protofi: IDENTICAL_ADDRESSES');
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), 'Protofi: ZERO_ADDRESS');
        require(getPair[token0][token1] == address(0), 'Protofi: PAIR_EXISTS'); // single check is sufficient
        bytes memory bytecode = type(ProtofiPair).creationCode;
        bytes32 salt = keccak256(abi.encodePacked(token0, token1));
        assembly {
            pair := create2(0, add(bytecode, 32), mload(bytecode), salt)
        }
        IProtofiPair(pair).initialize(token0, token1);
        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair; // populate mapping in the reverse direction
        allPairs.push(pair);
        emit PairCreated(token0, token1, pair, allPairs.length);
    }

    function setFeeTo(address _feeTo) external {
        require(msg.sender == feeToSetter, 'Protofi: FORBIDDEN');
        feeTo = _feeTo;
    }

    function setFeeToSetter(address _feeToSetter) external {
        require(msg.sender == feeToSetter, 'Protofi: FORBIDDEN');
        feeToSetter = _feeToSetter;
    }

    function feeAmount() external view returns (uint16){
        return _feeAmount;
    }

    function setFeeAmount(uint16 _newFeeAmount) external{  //Mod for fees
        // This parameter allow us to lower the fee which will be send to the feeTo address
        // 15 = 0.15% (all fee goes directly to the feeTo address)
        // If we update it to 5 for example, 0.10% are going to LP holder and 0.5% to the feeManager
        require(msg.sender == owner(), "caller is not the owner");
        require (_newFeeAmount >= 1, "amount too low");
        require (_newFeeAmount <= 15, "amount too big");
        _feeAmount = _newFeeAmount;
    }
}