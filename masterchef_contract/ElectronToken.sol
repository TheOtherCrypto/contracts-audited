// SPDX-License-Identifier: MIT
pragma solidity >= 0.6.12;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "./libs/ProtofiERC20.sol";
import "./interfaces/IMoneyPot.sol";

/**
This is the contract of the secondary token.

Features:
- Ownable
- Keeps track of every holder
- Can be swapped for the primary tokens
- Keeps track of the penalty over time to swap this token for the primary token

Owner --> Masterchef for farming features
 */
contract ElectronToken is ProtofiERC20("Electron Token", "ELCT") {
    using SafeMath for uint256;

    struct HolderInfo {
        uint256 avgTransactionBlock;
    }

    ProtofiERC20 public proton;
    bool private _isProtonSetup = false;

    IMoneyPot public moneyPot;
    bool private _isMoneyPotSetup = false;

    /// Penalty period expressed in blocks.
    uint256 public immutable SWAP_PENALTY_MAX_PERIOD; // default 129600 blocks (3d*24h*60m*60sec/2sec): after 72h penalty of holding electron, swap penalty is at the minimum (zero penalty)
    /// Penalty expressed in percentage points --> e.g. 30 means 30% of penalty
    uint256 public immutable SWAP_PENALTY_MAX_PER_ELCT; // default: 30, 30% => 1 electron = 0.3 proton

    // Keeps track of all the historical holders of Electron
    address[] private holdersAddresses;
    // Keeps track of all the addresses added to holdersAddresses
    mapping (address => bool) public wallets;
    // Keeps track of useful infos for each holder
    mapping(address => HolderInfo) public holdersInfo;

    constructor (uint256 swapPenaltyMaxPeriod, uint256 swapPenaltyMaxPerElectron) public{
        SWAP_PENALTY_MAX_PERIOD = swapPenaltyMaxPeriod;
        SWAP_PENALTY_MAX_PER_ELCT = swapPenaltyMaxPerElectron.mul(1e10);
    }

    /// Sets the reference to the primary token, can be done only once, be careful!
    function setupProton(ProtofiERC20 _proton) external onlyOwner {
        require(!_isProtonSetup, "The Proton token has already been set up. No one can change it anymore.");
        proton = _proton;
        _isProtonSetup = true;
    }

    /// Sets the reference to the MoneyPot, can be done only once, be careful!
    function setupMoneyPot(IMoneyPot _moneyPot) external onlyOwner {
        require(!_isMoneyPotSetup, "The Moneypot has already been set up. No one can change it anymore.");
        moneyPot = _moneyPot;
        _isMoneyPotSetup = true;
    }

    /**
    Calculate the penality for swapping ELCT to PROTO for a user.
    The penality decrease over time (by holding duration).
    From SWAP_PENALTY_MAX_PER_ELCT % to 0% on SWAP_PENALTY_MAX_PERIOD
    */
    function getPenaltyPercent(address _holderAddress) public view returns (uint256){
        HolderInfo storage holderInfo = holdersInfo[_holderAddress];
        if(block.number >= holderInfo.avgTransactionBlock.add(SWAP_PENALTY_MAX_PERIOD)){
            return 0;
        }
        if(block.number == holderInfo.avgTransactionBlock){
            return SWAP_PENALTY_MAX_PER_ELCT;
        }
        uint256 avgHoldingDuration = block.number.sub(holderInfo.avgTransactionBlock);
        return SWAP_PENALTY_MAX_PER_ELCT.sub(
            SWAP_PENALTY_MAX_PER_ELCT.mul(avgHoldingDuration).div(SWAP_PENALTY_MAX_PERIOD)
        );
    }

    /// Allow use to exchange (swap) their electron to proton
    function swapToProton(uint256 _amount) external {
        require(_amount > 0, "amount 0");
        address _from = msg.sender;
        // Get the amount of the primary token to be received
        uint256 protonAmount = _swapProtonAmount( _from, _amount);
        holdersInfo[_from].avgTransactionBlock = _getAvgTransactionBlock(_from, holdersInfo[_from], _amount, true);
        
        // Burn ELCT and mint PROTO
        super._burn(_from, _amount);

        // Moving delegates with the call to _burn
        emit DelegateChanged(_from, _delegates[_from], _delegates[BURN_ADDRESS]);
        _moveDelegates(_delegates[_from], _delegates[BURN_ADDRESS], _amount);

        proton.mint(_from, protonAmount);

        if (address(moneyPot) != address(0)) {
            moneyPot.updateElectronHolder(_from);
        }
    }

    /**
    @notice Preview swap return in proton with _electronAmount by _holderAddress
    this function is used by front-end to show how much PROTO will be retrieved if _holderAddress swap _electronAmount
    */
    function previewSwapProtonExpectedAmount(address _holderAddress, uint256 _electronAmount) external view returns (uint256 expectedProton){
        return _swapProtonAmount( _holderAddress, _electronAmount);
    }

    /**
    @notice Preview swap return in proton from all the addresses holding ELCT
    This function is used by front-end to show how much PROTO will be generated if all the holders of ELCT swap all ELCTS for PROTOS
    */
    function previewTotalSwapElectronToProton() external view returns (uint256 expectedProton){

        uint256 totalProton = 0;
        // For each holder, update the total PROTOs that can be generated
        for(uint index = 0; index < holdersAddresses.length; index++){
            address tmpaddress = holdersAddresses[index];
            uint256 tmpbalance = balanceOf(tmpaddress);
            totalProton = totalProton.add(_swapProtonAmount(tmpaddress, tmpbalance));
        }
        return totalProton;
    }

    /// @notice Calculate the adjustment for a user if he want to swap _electronAmount to proton
    function _swapProtonAmount(address _holderAddress, uint256 _electronAmount) internal view returns (uint256 expectedProton){
        require(balanceOf(_holderAddress) >= _electronAmount, "Not enough electron");
        uint256 penalty = getPenaltyPercent(_holderAddress);
        if(penalty == 0){
            return _electronAmount;
        }

        return _electronAmount.sub(_electronAmount.mul(penalty).div(1e12));
    }

    /**
    @notice Calculate average deposit/withdraw block for _holderAddress

    @dev The average transaction block is:
    - set to 0 if the user swaps all his electron to proton
    - set to the previous avgTransactionBlock if the user does not swap all his electron
    - is updated if the holder gets new electron
    Basically, avgTransactionBlock is updated to a higher value only if _holderAddress receives new electron,
    otherwise avgTransactionBlock stays the same or go to 0 if everything is swapped or sent.
     */
    function _getAvgTransactionBlock(address _holderAddress, HolderInfo storage holderInfo, uint256 _electronAmount, bool _onWithdraw) internal view returns (uint256){
        if (balanceOf(_holderAddress) == 0) {
            return block.number;
        }
        uint256 minAvgTransactionBlockPossible = block.number.sub(SWAP_PENALTY_MAX_PERIOD);
        uint256 holderAvgTransactionBlock = holderInfo.avgTransactionBlock > minAvgTransactionBlockPossible ? holderInfo.avgTransactionBlock : minAvgTransactionBlockPossible;

        uint256 transactionBlockWeight;
        if (_onWithdraw) {
            if (balanceOf(_holderAddress) == _electronAmount) {
                return 0; // Average transaction block is the lowest possible block
            }
            else {
                return holderAvgTransactionBlock;
            }
        }
        else {
            transactionBlockWeight = (balanceOf(_holderAddress).mul(holderAvgTransactionBlock).add(block.number.mul(_electronAmount)));
        }

        uint256 avgTransactionBlock = transactionBlockWeight.div(balanceOf(_holderAddress).add(_electronAmount));
        return avgTransactionBlock > minAvgTransactionBlockPossible ? avgTransactionBlock : minAvgTransactionBlockPossible;
    }


    /// @notice Creates `_amount` token to `_to`.
    function mint(address _to, uint256 _amount) external virtual override onlyOwner {
        HolderInfo storage holder = holdersInfo[_to];
        // avgTransactionBlock is updated accordingly to the amount minted
        holder.avgTransactionBlock = _getAvgTransactionBlock(_to, holder, _amount, false);

        if(wallets[_to] == false){
            // Add holder to historical holders
            holdersAddresses.push(_to);
            wallets[_to] = true;
        }

        _mint(_to, _amount);
        _moveDelegates(address(0), _delegates[_to], _amount);

        if (address(moneyPot) != address(0)) {
            moneyPot.updateElectronHolder(_to);
        }
    }

    /// @dev overrides transfer function to meet tokenomics of ELCT
    function _transfer(address _sender, address _recipient, uint256 _amount) internal virtual override {
        holdersInfo[_sender].avgTransactionBlock = _getAvgTransactionBlock(_sender, holdersInfo[_sender], _amount, true);
        if (_recipient == BURN_ADDRESS) {
            super._burn(_sender, _amount);
            if (address(moneyPot) != address(0)) {
                moneyPot.updateElectronHolder(_sender);
            }
        } else {
            holdersInfo[_recipient].avgTransactionBlock = _getAvgTransactionBlock(_recipient, holdersInfo[_recipient], _amount, false);
            super._transfer(_sender, _recipient, _amount);

            if (address(moneyPot) != address(0)) {
                moneyPot.updateElectronHolder(_sender);
                if (_sender != _recipient){
                    moneyPot.updateElectronHolder(_recipient);
                }
            }
        }
        if(wallets[_recipient] == false){
            // Add holder to historical holders
            holdersAddresses.push(_recipient);
            wallets[_recipient] = true;
        }

        // Moving delegates while transferring tokens - Valid also for the _burn call
        emit DelegateChanged(_sender, _delegates[msg.sender], _delegates[_recipient]);
        _moveDelegates(_delegates[msg.sender], _delegates[_recipient], _amount);
    }

    // Copied and modified from YAM code:
    // https://github.com/yam-finance/yam-protocol/blob/master/contracts/token/YAMGovernanceStorage.sol
    // https://github.com/yam-finance/yam-protocol/blob/master/contracts/token/YAMGovernance.sol
    // Which is copied and modified from COMPOUND:
    // https://github.com/compound-finance/compound-protocol/blob/master/contracts/Governance/Comp.sol

    /// @dev A record of each accounts delegate
    mapping(address => address) internal _delegates;

    /// @notice A checkpoint for marking number of votes from a given block
    struct Checkpoint {
        uint32 fromBlock;
        uint256 votes;
    }

    /// @notice A record of votes checkpoints for each account, by index
    mapping(address => mapping(uint32 => Checkpoint)) public checkpoints;

    /// @notice The number of checkpoints for each account
    mapping(address => uint32) public numCheckpoints;

    /// @notice The EIP-712 typehash for the contract's domain
    bytes32 public constant DOMAIN_TYPEHASH =
    keccak256("EIP712Domain(string name,uint256 chainId,address verifyingContract)");

    /// @notice The EIP-712 typehash for the delegation struct used by the contract
    bytes32 public constant DELEGATION_TYPEHASH =
    keccak256("Delegation(address delegatee,uint256 nonce,uint256 expiry)");

    /// @notice A record of states for signing / validating signatures
    mapping(address => uint) public nonces;

    /// @notice An event thats emitted when an account changes its delegate
    event DelegateChanged(address indexed delegator, address indexed fromDelegate, address indexed toDelegate);

    /// @notice An event thats emitted when a delegate account's vote balance changes
    event DelegateVotesChanged(address indexed delegate, uint previousBalance, uint newBalance);

    /**
     * @notice Delegate votes from `msg.sender` to `delegatee`
     * @param delegator The address to get delegatee for
     */
    function delegates(address delegator)
    external
    view
    returns (address)
    {
        return _delegates[delegator];
    }

    /**
     * @notice Delegate votes from `msg.sender` to `delegatee`
     * @param delegatee The address to delegate votes to
     */
    function delegate(address delegatee) external {
        return _delegate(msg.sender, delegatee);
    }

    /**
     * @notice Delegates votes from signatory to `delegatee`
     * @param delegatee The address to delegate votes to
     * @param nonce The contract state required to match the signature
     * @param expiry The time at which to expire the signature
     * @param v The recovery byte of the signature
     * @param r Half of the ECDSA signature pair
     * @param s Half of the ECDSA signature pair
     */
    function delegateBySig(
        address delegatee,
        uint nonce,
        uint expiry,
        uint8 v,
        bytes32 r,
        bytes32 s
    )
    external
    {
        bytes32 domainSeparator = keccak256(
            abi.encode(
                DOMAIN_TYPEHASH,
                keccak256(bytes(name())),
                getChainId(),
                address(this)
            )
        );

        bytes32 structHash = keccak256(
            abi.encode(
                DELEGATION_TYPEHASH,
                delegatee,
                nonce,
                expiry
            )
        );

        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                domainSeparator,
                structHash
            )
        );

        address signatory = ecrecover(digest, v, r, s);
        require(signatory != address(0), "PROTO::delegateBySig: invalid signature");
        require(nonce == nonces[signatory]++, "PROTO::delegateBySig: invalid nonce");
        require(now <= expiry, "PROTO::delegateBySig: signature expired");
        return _delegate(signatory, delegatee);
    }

    /**
     * @notice Gets the current votes balance for `account`
     * @param account The address to get votes balance
     * @return The number of current votes for `account`
     */
    function getCurrentVotes(address account)
    external
    view
    returns (uint256)
    {
        uint32 nCheckpoints = numCheckpoints[account];
        return nCheckpoints > 0 ? checkpoints[account][nCheckpoints - 1].votes : 0;
    }

    /**
     * @notice Determine the prior number of votes for an account as of a block number
     * @dev Block number must be a finalized block or else this function will revert to prevent misinformation.
     * @param account The address of the account to check
     * @param blockNumber The block number to get the vote balance at
     * @return The number of votes the account had as of the given block
     */
    function getPriorVotes(address account, uint blockNumber)
    external
    view
    returns (uint256)
    {
        require(blockNumber < block.number, "PROTO::getPriorVotes: not yet determined");

        uint32 nCheckpoints = numCheckpoints[account];
        if (nCheckpoints == 0) {
            return 0;
        }

        // First check most recent balance
        if (checkpoints[account][nCheckpoints - 1].fromBlock <= blockNumber) {
            return checkpoints[account][nCheckpoints - 1].votes;
        }

        // Next check implicit zero balance
        if (checkpoints[account][0].fromBlock > blockNumber) {
            return 0;
        }

        uint32 lower = 0;
        uint32 upper = nCheckpoints - 1;
        while (upper > lower) {
            uint32 center = upper - (upper - lower) / 2;
            // ceil, avoiding overflow
            Checkpoint memory cp = checkpoints[account][center];
            if (cp.fromBlock == blockNumber) {
                return cp.votes;
            } else if (cp.fromBlock < blockNumber) {
                lower = center;
            } else {
                upper = center - 1;
            }
        }
        return checkpoints[account][lower].votes;
    }

    function _delegate(address delegator, address delegatee)
    internal
    {
        address currentDelegate = _delegates[delegator];
        uint256 delegatorBalance = balanceOf(delegator);
        // balance of underlying PROTOs (not scaled);
        _delegates[delegator] = delegatee;

        emit DelegateChanged(delegator, currentDelegate, delegatee);

        _moveDelegates(currentDelegate, delegatee, delegatorBalance);
    }

    function _moveDelegates(address srcRep, address dstRep, uint256 amount) internal {
        if (srcRep != dstRep && amount > 0) {
            if (srcRep != address(0)) {
                // decrease old representative
                uint32 srcRepNum = numCheckpoints[srcRep];
                uint256 srcRepOld = srcRepNum > 0 ? checkpoints[srcRep][srcRepNum - 1].votes : 0;
                uint256 srcRepNew = srcRepOld.sub(amount);
                _writeCheckpoint(srcRep, srcRepNum, srcRepOld, srcRepNew);
            }

            if (dstRep != address(0)) {
                // increase new representative
                uint32 dstRepNum = numCheckpoints[dstRep];
                uint256 dstRepOld = dstRepNum > 0 ? checkpoints[dstRep][dstRepNum - 1].votes : 0;
                uint256 dstRepNew = dstRepOld.add(amount);
                _writeCheckpoint(dstRep, dstRepNum, dstRepOld, dstRepNew);
            }
        }
    }

    function _writeCheckpoint(
        address delegatee,
        uint32 nCheckpoints,
        uint256 oldVotes,
        uint256 newVotes
    )
    internal
    {
        uint32 blockNumber = safe32(block.number, "PROTO::_writeCheckpoint: block number exceeds 32 bits");

        if (nCheckpoints > 0 && checkpoints[delegatee][nCheckpoints - 1].fromBlock == blockNumber) {
            checkpoints[delegatee][nCheckpoints - 1].votes = newVotes;
        } else {
            checkpoints[delegatee][nCheckpoints] = Checkpoint(blockNumber, newVotes);
            numCheckpoints[delegatee] = nCheckpoints + 1;
        }

        emit DelegateVotesChanged(delegatee, oldVotes, newVotes);
    }

    function safe32(uint n, string memory errorMessage) internal pure returns (uint32) {
        require(n < 2 ** 32, errorMessage);
        return uint32(n);
    }

    function getChainId() internal pure returns (uint) {
        uint256 chainId;
        assembly {chainId := chainid()}
        return chainId;
    }
}