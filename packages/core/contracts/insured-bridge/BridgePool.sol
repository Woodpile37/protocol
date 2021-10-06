// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "./interfaces/BridgeAdminInterface.sol";
import "./interfaces/BridgePoolInterface.sol";

import "../oracle/interfaces/SkinnyOptimisticOracleInterface.sol";
import "../oracle/interfaces/StoreInterface.sol";
import "../oracle/interfaces/FinderInterface.sol";
import "../oracle/implementation/Constants.sol";

import "../common/implementation/AncillaryData.sol";
import "../common/implementation/Testable.sol";
import "../common/implementation/FixedPoint.sol";
import "../common/implementation/MultiCaller.sol";
import "../common/implementation/Lockable.sol";
import "../common/implementation/ExpandedERC20.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @notice Contract deployed on L1 that provides methods for "Relayers" to fulfill deposit orders that originated on L2.
 * The Relayers can either post capital to fulfill the deposit (instant relay), or request that the funds are taken out
 * of a passive liquidity provider pool following a challenge period (slow relay). This contract ingests liquidity from
 * passive liquidity providers and returns them claims to withdraw their funds. Liquidity providers are incentivized
 * to post collateral by earning a fee per fulfilled deposit order.
 * @dev A "Deposit" is an order to send capital from L2 to L1, and a "Relay" is a fulfillment attempt of that order.
 */
contract BridgePool is Testable, BridgePoolInterface, ExpandedERC20, MultiCaller, Lockable {
    using SafeERC20 for IERC20;
    using FixedPoint for FixedPoint.Unsigned;

    // Token that this contract receives as LP deposits.
    IERC20 public override l1Token;

    // Track the total number of relays and uniquely identifies relays.
    uint32 public numberOfRelays;

    // Reserves that are unutilized and withdrawable.
    uint256 public liquidReserves;

    // Reserves currently utilized due to L2-L1 transactions in flight.
    int256 public utilizedReserves;

    // Reserves that are not yet utilized but are pre-allocated for a pending relay.
    uint256 public pendingReserves;

    // Exponential decay exchange rate to accumulate fees to LPs over time.
    uint256 public lpFeeRatePerSecond;

    // Last timestamp that LP fees were updated.
    uint256 public lastLpFeeUpdate;

    // Cumulative undistributed LP fees. As fees accumulate, they are subtracted from this number.
    uint256 public undistributedLpFees;

    // Administrative contract that deployed this contract and also houses all state variables needed to relay deposits.
    BridgeAdminInterface public bridgeAdmin;

    // Store local instances of the contract instances to save gas relaying. Can be sync with the Finder at any time.
    StoreInterface public store;
    SkinnyOptimisticOracleInterface public optimisticOracle;

    // Store local instances of contract params to save gas relaying. Can be synced with the BridgeAdmin at any time.
    uint64 public proposerBondPct;
    uint64 public optimisticOracleLiveness;
    bytes32 public identifier;

    // A Relay represents an attempt to finalize a cross-chain transfer that originated on an L2 DepositBox contract.
    // The flow chart between states is as follows:
    // - Begin at Uninitialized.
    // - When relayDeposit() is called, a new relay is created with state Pending and mapped to the L2 deposit hash.
    // - If the relay is disputed, the RelayData gets deleted and the L2 deposit hash has no relay mapped to it anymore.
    // - The above statements enable state to transfer between the Uninitialized and Pending states.
    // - When settleRelay() is successfully called, the relay state gets set to Finalized and cannot change from there.
    // - It is impossible for a relay to be deleted when in Finalized state (and have its state set to Uninitialized)
    //   because the only way for settleRelay() to succeed is if the price has resolved on the OptimisticOracle.
    // - You cannot dispute an already resolved request on the OptimisticOracle. Moreover, the mapping from
    //   a relay's ancillary data hash to its deposit hash is deleted after a successful settleRelay() call.
    enum RelayState { Uninitialized, Pending, Finalized }

    // Data from L2 deposit transaction.
    struct DepositData {
        uint8 chainId;
        uint64 depositId;
        address l1Recipient;
        address l2Sender;
        uint256 amount;
        uint64 slowRelayFeePct;
        uint64 instantRelayFeePct;
        uint64 quoteTimestamp;
    }

    // Each L2 Deposit can have one Relay attempt at any one time. A Relay attempt is characterized by its RelayData.
    struct RelayData {
        RelayState relayState;
        address slowRelayer;
        uint32 relayId;
        uint64 realizedLpFeePct;
        uint256 priceRequestTime;
    }

    // Associate deposits with pending relay data. When the mapped relay hash is empty, new relay attempts can be made
    // for this deposit. The relay data contains information necessary to pay out relayers on successful relay.
    // Relay hashes are deleted when they are disputed on the OptimisticOracle.
    mapping(bytes32 => bytes32) public relays;

    // Associates a relay request's ancillary data with the deposit hash that the relay request was linked with. This
    // mapping is used by the OptimisticOracle callback functions (i.e. priceDisputed) to identify the
    // relay request that was disputed or settled.
    mapping(bytes32 => bytes32) public relayRequestAncillaryData;

    // Map hash of deposit and realized-relay fee to instant relayers. This mapping is checked at settlement time
    // to determine if there was a valid instant relayer.
    mapping(bytes32 => address) public instantRelays;

    event LiquidityAdded(address indexed token, uint256 amount, uint256 lpTokensMinted, address liquidityProvider);
    event LiquidityRemoved(address indexed token, uint256 amount, uint256 lpTokensBurnt, address liquidityProvider);
    event DepositRelayed(
        bytes32 indexed depositHash,
        DepositData depositData,
        address l1Token,
        RelayData relay,
        bytes32 relayAncillaryDataHash
    );
    event RelaySpedUp(bytes32 indexed depositHash, address indexed instantRelayer, RelayData relay);
    event RelaySettled(bytes32 indexed depositHash, address indexed caller, RelayData relay);
    event BridgePoolAdminTransferred(address oldAdmin, address newAdmin);

    modifier onlyFromOptimisticOracle() {
        require(msg.sender == address(optimisticOracle), "Caller must be OptimisticOracle");
        _;
    }

    /**
     * @notice Construct the Bridge Pool
     * @param _lpTokenName Name of the LP token to be deployed by this contract.
     * @param _lpTokenSymbol Symbol of the LP token to be deployed by this contract.
     * @param _bridgeAdmin Admin contract deployed alongside on L1. Stores global variables and has owner control.
     * @param _l1Token Address of the L1 token that this bridgePool holds. This is the token LPs deposit and is bridged.
     * @param _lpFeeRatePerSecond Interest rate payment that scales the amount of pending fees per second paid to LPs.
     * @param _timer Timer used to synchronize contract time in testing. Set to 0x000... in production.
     */
    constructor(
        string memory _lpTokenName,
        string memory _lpTokenSymbol,
        address _bridgeAdmin,
        address _l1Token,
        uint256 _lpFeeRatePerSecond,
        address _timer
    ) Testable(_timer) ExpandedERC20(_lpTokenName, _lpTokenSymbol, 18) {
        require(bytes(_lpTokenName).length != 0 && bytes(_lpTokenSymbol).length != 0, "Bad LP token name or symbol");
        bridgeAdmin = BridgeAdminInterface(_bridgeAdmin);

        l1Token = IERC20(_l1Token);
        lastLpFeeUpdate = getCurrentTime();
        lpFeeRatePerSecond = _lpFeeRatePerSecond;

        syncWithFinderAddresses(); // Fetch OptimisticOracle and Store addresses from the Finder.
        syncWithBridgeAdminParams(); // Fetch ProposerBondPct OptimisticOracleLiveness, Identifier from the BridgeAdmin.
    }

    /*************************************************
     *          LIQUIDITY PROVIDER FUNCTIONS         *
     *************************************************/

    /**
     * @notice Add liquidity to the bridge pool. Pulls l1tokens from the callers wallet. The caller is sent back a
     * commensurate number of LP tokens (minted to their address) at the prevailing exchange rate.
     * @dev The caller must approve this contract to transfer `l1TokenAmount` amount of l1Token.
     * @dev Reentrancy guard not added to this function because this indirectly calls sync() which is guarded.
     * @param l1TokenAmount Number of l1Token to add as liquidity.
     */
    function addLiquidity(uint256 l1TokenAmount) public {
        l1Token.safeTransferFrom(msg.sender, address(this), l1TokenAmount);

        uint256 lpTokensToMint = (l1TokenAmount * 1e18) / exchangeRateCurrent();

        _mint(msg.sender, lpTokensToMint);

        liquidReserves += l1TokenAmount;

        emit LiquidityAdded(address(l1Token), l1TokenAmount, lpTokensToMint, msg.sender);
    }

    /**
     * @notice Removes liquidity to the bridge pool. Burns lpTokenAmount LP tokens from the callers wallet. The caller
     * is sent back a commensurate number of l1Tokens at the prevailing exchange rate.
     * @dev The caller does not need to approve the spending of LP tokens as this method directly uses the burn logic.
     * @dev Reentrancy guard not added to this function because this indirectly calls sync() which is guarded.
     * @param lpTokenAmount Number of lpTokens to redeem for underlying.
     */
    function removeLiquidity(uint256 lpTokenAmount) public {
        uint256 l1TokensToReturn = (lpTokenAmount * exchangeRateCurrent()) / 1e18;

        // Check that there is enough liquid reserves to withdraw the requested amount.
        require(liquidReserves >= (pendingReserves + l1TokensToReturn), "Utilization too high to remove");

        _burn(msg.sender, lpTokenAmount);

        liquidReserves -= l1TokensToReturn;

        l1Token.safeTransfer(msg.sender, l1TokensToReturn);

        emit LiquidityRemoved(address(l1Token), l1TokensToReturn, lpTokenAmount, msg.sender);
    }

    /**************************************
     *          RELAYER FUNCTIONS         *
     **************************************/

    /**
     * @notice Called by Relayer to execute a slow relay from L2 to L1, fulfilling a corresponding deposit order.
     * @dev There can only be one pending relay for a deposit.
     * @dev Caller must have approved this contract to spend the total bond for `l1Token`.
     * @param chainId Unique network ID on which deposit event occurred.
     * @param depositId Unique ID corresponding to deposit order that caller wants to relay.
     * @param l1Recipient Address on this network who should receive the relayed deposit.
     * @param l2Sender Address on the L2 network of depositor.
     * @param amount Amount deposited on L2 to be brought over to L1.
     * @param slowRelayFeePct Max fraction of `amount` that the depositor is willing to pay as a slow relay fee.
     * @param instantRelayFeePct Fraction of `amount` that the depositor is willing to pay as a instant relay fee.
     * @param quoteTimestamp Timestamp up until the depositor is willing to accept an LP quotation for.
     * @param realizedLpFeePct LP fee calculated off-chain considering the L1 pool liquidity at deposit time, before
     *      quoteTimestamp. The OO acts to verify the correctness of this realized fee. Can not exceed 50%.
     */
    function relayDeposit(
        uint8 chainId,
        uint64 depositId,
        address l1Recipient,
        address l2Sender,
        uint256 amount,
        uint64 slowRelayFeePct,
        uint64 instantRelayFeePct,
        uint64 quoteTimestamp,
        uint64 realizedLpFeePct
    ) public nonReentrant() {
        // The realizedLPFeePct should never be greater than 0.5e18 and the slow and instant relay fees should never be
        // more than 0.25e18 each. Therefore, the sum of all fee types can never exceed 1e18 (or 100%).
        require(slowRelayFeePct < 0.25e18 && instantRelayFeePct < 0.25e18 && realizedLpFeePct < 0.5e18);

        // Check if there is a pending relay for this deposit.
        DepositData memory depositData =
            DepositData({
                chainId: chainId,
                depositId: depositId,
                l1Recipient: l1Recipient,
                l2Sender: l2Sender,
                amount: amount,
                slowRelayFeePct: slowRelayFeePct,
                instantRelayFeePct: instantRelayFeePct,
                quoteTimestamp: quoteTimestamp
            });
        bytes32 depositHash = _getDepositHash(depositData);

        // Note: A disputed relay deletes the stored relay hash and enables this require statement to pass.
        require(relays[depositHash] == bytes32(0), "Pending relay exists");

        // If no pending relay for this deposit, then associate the caller's relay attempt with it.
        uint256 priceRequestTime = getCurrentTime();

        // Save hash of new relay attempt parameters.
        RelayData memory relayData =
            RelayData({
                relayState: RelayState.Pending,
                slowRelayer: msg.sender, // Note: Increment numberOfRelays at the same time as setting relayId to its current value.
                relayId: numberOfRelays++,
                realizedLpFeePct: realizedLpFeePct,
                priceRequestTime: priceRequestTime
            });
        relays[depositHash] = _getRelayDataHash(relayData);

        bytes32 relayHash = _getRelayHash(depositData, relayData);
        bytes memory ancillaryData = _getRelayAncillaryData(relayHash);
        relayRequestAncillaryData[keccak256(ancillaryData)] = depositHash;

        // Sanity check that pool has enough balance to cover relay amount + proposer reward. Reward amount will be
        // paid on settlement after the OptimisticOracle price request has passed the challenge period.
        uint256 proposerBond = _getProposerBond(amount);
        require(
            l1Token.balanceOf(address(this)) >= amount + proposerBond && liquidReserves >= amount + proposerBond,
            "Insufficient pool balance"
        );

        // Request a price for the relay identifier and propose "true" optimistically. This method will pull the
        // (proposer reward + proposer bond + final fee) from the caller. We need to set a new price request timestamp
        // instead of default setting to equal to the `depositTimestamp`, which is dependent on the L2 VM on which the
        // DepositContract is deployed. Imagine if the timestamps on the L2 have an offset that are always "in the
        // future" relative to L1 blocks, then the OptimisticOracle would always reject requests.
        _requestAndProposeOraclePriceRelay(amount, priceRequestTime, ancillaryData);

        pendingReserves += amount; // Book off maximum liquidity used by this relay in the pending reserves.

        emit DepositRelayed(depositHash, depositData, address(l1Token), relayData, relayHash);
    }

    /**
     * @notice Instantly relay a deposit amount minus fees to the l1Recipient. Instant relayer earns a reward following
     * the pending relay challenge period.
     * @dev We assume that the caller has performed an off-chain check that the deposit data they are attempting to
     * relay is valid. If the deposit data is invalid, then the instant relayer has no recourse
     * to receive their funds back after the invalid deposit data is disputed. Moreover, no one will be able to
     * resubmit a relay for the invalid deposit data because they know it will get disputed again. On the other hand,
     * if the deposit data is valid, then even if it is falsely disputed, the instant relayer will eventually get
     * reimbursed because someone else will be incentivized to resubmit the relay to earn slow relayer rewards. Once the
     * valid relay is finalized, the instant relayer will be reimbursed. Therefore, the caller has the same
     * responsibility as the disputer in validating the relay data.
     * @dev Caller must have approved this contract to spend the deposit amount of L1 tokens to relay. There can only
     * be one instant relayer per relay attempt.
     * @param depositData Unique set of L2 deposit data that caller is trying to instantly relay.
     * @param relayData Parameters of Relay that caller is attempting to speedup. Must hash to the stored relay hash
     * for this deposit or this method will revert.
     */
    function speedUpRelay(DepositData memory depositData, RelayData memory relayData) public nonReentrant() {
        bytes32 depositHash = _getDepositHash(depositData);
        _validateRelayDataHash(depositHash, relayData);

        bytes32 instantRelayHash = _getInstantRelayHash(depositHash, relayData);
        require(
            // Can only speed up a pending relay without an existing instant relay associated with it.
            relayData.relayState == RelayState.Pending && instantRelays[instantRelayHash] == address(0),
            "Relay cannot be sped up"
        );
        instantRelays[instantRelayHash] = msg.sender;

        // Pull relay amount minus fees from caller and send to the deposit l1Recipient. The total fees paid is the sum
        // of the LP fees, the relayer fees and the instant relay fee.
        uint256 feesTotal =
            _getAmountFromPct(
                relayData.realizedLpFeePct + depositData.slowRelayFeePct + depositData.instantRelayFeePct,
                depositData.amount
            );

        l1Token.safeTransferFrom(msg.sender, depositData.l1Recipient, depositData.amount - feesTotal);

        emit RelaySpedUp(depositHash, msg.sender, relayData);
    }

    /**
     * @notice Reward relayers if a pending relay price request has a price available on the OptimisticOracle. Mark
     * the relay as complete.
     * @param depositData Unique set of L2 deposit data that caller is trying to settle a relay for.
     * @param relayData Parameters of Relay that caller is attempting to settle. Must hash to the stored relay hash
     * for this deposit.
     * @param ancillaryData Relay price request's ancillary data. Used to check status of relay price request.
     * @param request Relay price request struct. Used to check status of relay price request.
     */
    function settleRelay(
        DepositData memory depositData,
        RelayData memory relayData,
        bytes memory ancillaryData,
        SkinnyOptimisticOracleInterface.Request memory request
    ) public nonReentrant() {
        bytes32 depositHash = _getDepositHash(depositData);
        _validateRelayDataHash(depositHash, relayData);
        require(relayData.relayState == RelayState.Pending, "Already settled");

        // Optimistically try to settle relay. If this transaction settles the relay, then check the newly resolved
        // price. Otherwise grab the already resolved price.
        try
            optimisticOracle.settle(
                address(this),
                bridgeAdmin.identifier(),
                uint32(relayData.priceRequestTime),
                ancillaryData,
                request
            )
        returns (
            uint256 payout, // Unused parameter, as we only care to check whether the price resolved to True or False.
            int256 resolvedPrice
        ) {
            require(resolvedPrice == int256(1e18), "Settle relay iff price is True");
        } catch {
            // We could not settle the request, therefore check if its already been resolved.
            require(
                optimisticOracle.hasPrice(
                    address(this),
                    bridgeAdmin.identifier(),
                    uint32(relayData.priceRequestTime),
                    ancillaryData,
                    request
                ) && request.resolvedPrice == int256(1e18),
                "Settle relay iff price is True"
            );
        }

        // Update the relay state to Finalized. This prevents any re-settling of a relay.
        relays[depositHash] = _getRelayDataHash(
            RelayData({
                relayState: RelayState.Finalized,
                slowRelayer: relayData.slowRelayer,
                relayId: relayData.relayId,
                realizedLpFeePct: relayData.realizedLpFeePct,
                priceRequestTime: relayData.priceRequestTime
            })
        );

        // Reward relayers and pay out l1Recipient.
        // At this point there are two possible cases:
        // - This was a slow relay: In this case, a) pay the slow relayer their reward and b) pay the l1Recipient of the
        //      amount minus the realized LP fee and the slow Relay fee. The transfer was not sped up so no instant fee.
        // - This was a instant relay: In this case, a) pay the slow relayer their reward and b) pay the instant relayer
        //      the full bridging amount, minus the realized LP fee and minus the slow relay fee. When the instant
        //      relayer called speedUpRelay they were docked this same amount, minus the instant relayer fee. As a
        //      result, they are effectively paid what they spent when speeding up the relay + the instantRelayFee.

        uint256 instantRelayerOrRecipientAmount =
            depositData.amount -
                _getAmountFromPct(relayData.realizedLpFeePct + depositData.slowRelayFeePct, depositData.amount);

        // Refund the instant relayer iff the instant relay params match the approved relay.
        bytes32 instantRelayHash = _getInstantRelayHash(depositHash, relayData);
        address instantRelayer = instantRelays[instantRelayHash];

        l1Token.safeTransfer(
            instantRelayer != address(0) ? instantRelayer : depositData.l1Recipient,
            instantRelayerOrRecipientAmount
        );

        // The slow relayer gets paid the slow relay fee. This is the same irrespective if the relay was sped up or not.
        uint256 slowRelayerAmount = _getAmountFromPct(depositData.slowRelayFeePct, depositData.amount);
        l1Token.safeTransfer(relayData.slowRelayer, slowRelayerAmount);

        uint256 totalAmountSent = instantRelayerOrRecipientAmount + slowRelayerAmount;

        // Update reserves by amounts changed and allocated LP fees.
        pendingReserves -= depositData.amount;
        liquidReserves -= totalAmountSent;
        utilizedReserves += int256(totalAmountSent);
        updateAccumulatedLpFees();
        allocateLpFees(_getAmountFromPct(relayData.realizedLpFeePct, depositData.amount));

        emit RelaySettled(depositHash, msg.sender, relayData);

        // Clean up state storage and receive gas refund. This also prevents `priceDisputed()` from being able to reset
        // this newly Finalized relay state.
        delete instantRelays[instantRelayHash];
        delete relayRequestAncillaryData[keccak256(ancillaryData)];
    }

    /**
     * @notice Callback for disputes, deletes disputed relay allowing a follow-up relay.
     * @dev timestamp and identifier are unused because ancillaryData contains a relay nonce and uniquely
     * identifies a relay request.
     * @param identifier price identifier for relay request.
     * @param timestamp timestamp for relay request.
     * @param ancillaryData ancillary data for relay request.
     * @param request disputed relay request params.
     */
    function priceDisputed(
        // Unused, but the identifier should be same as bridgeAdmin.identifier()
        bytes32 identifier,
        // Unused, but timestamp should be same as the hashed relay.priceRequestTime included in relays[depositHash]
        uint32 timestamp,
        bytes memory ancillaryData,
        // Unused as all of the relay data is hashed and stored in relays[depositHash], and we can lookup depositHash
        // using the ancillaryData
        SkinnyOptimisticOracleInterface.Request memory request
    ) external onlyFromOptimisticOracle {
        bytes32 depositHash = relayRequestAncillaryData[keccak256(ancillaryData)];
        // We can delete the pending relay hash because we will still store data that must be carried over to a follow
        // up relay, namely the `instantRelayer` address which is stored in a separate mappign from the relay hashes.
        delete relays[depositHash];
    }

    /**
     * @notice Synchronize any balance changes in this contract with the utilized & liquid reserves. This would be done
     * at the conclusion of an L2->L1 token transfer via the canonical token bridge.
     */
    function sync() public nonReentrant() {
        // Check if the l1Token balance of the contract is greater than the liquidReserves. If it is then the bridging
        // action from L2->L1 has concluded and the local accounting can be updated.
        uint256 l1TokenBalance = l1Token.balanceOf(address(this));
        if (l1TokenBalance > liquidReserves) {
            // utilizedReserves can go to less than zero. This will happen if the accumulated fees exceeds the current
            // outstanding utilization. In other words, if outstanding bridging transfers are 0 then utilizedReserves
            // will equal the total LP fees accumulated over all time.
            utilizedReserves -= int256(l1TokenBalance - liquidReserves);
            liquidReserves = l1TokenBalance;
        }
    }

    /**
     * @notice Computes the exchange rate between LP tokens and L1Tokens. Used when adding/removing liquidity.
     */
    function exchangeRateCurrent() public returns (uint256) {
        if (totalSupply() == 0) return 1e18; //initial rate is 1 pre any mint action.

        // First, update fee counters and local accounting of finalized transfers from L2->L1.
        updateAccumulatedLpFees(); // Accumulate all allocated fees from the last time this method was called.
        sync(); // Fetch any balance changes due to token bridging finalization and factor them in.

        // ExchangeRate := (liquidReserves + utilizedReserves - undistributedLpFees) / lpTokenSupply
        uint256 numerator = liquidReserves - undistributedLpFees;
        if (utilizedReserves > 0) numerator += uint256(utilizedReserves);
        else numerator -= uint256(utilizedReserves * -1);
        return (numerator * 1e18) / totalSupply();
    }

    /**
     * @notice Computes the current liquidity utilization ratio.
     * @dev Used in computing realizedLpFeePct off-chain.
     */
    function liquidityUtilizationCurrent() public returns (uint256) {
        return liquidityUtilizationPostRelay(0);
    }

    /**
     * @notice Computes the liquidity utilization ratio post a relay of known size.
     * @dev Used in computing realizedLpFeePct off-chain.
     * @param relayedAmount Size of the relayed deposit to factor into the utilization calculation.
     */
    function liquidityUtilizationPostRelay(uint256 relayedAmount) public returns (uint256) {
        sync(); // Fetch any balance changes due to token bridging finalization and factor them in.

        // The liquidity utilization ratio is the ratio of utilized liquidity (pendingReserves + relayedAmount
        // +utilizedReserves) divided by the liquid reserves.
        uint256 numerator = pendingReserves + relayedAmount;
        if (utilizedReserves > 0) numerator += uint256(utilizedReserves);
        else numerator -= uint256(utilizedReserves * -1);

        // There are two cases where liquid reserves could be zero. Handle accordingly to avoid division by zero:
        // a) the pool is new and there no funds in it nor any bridging actions have happened. In this case the
        // numerator is 0 and liquid reserves are 0. The utilization is therefore 0.
        if (numerator == 0 && liquidReserves == 0) return 0;
        // b) the numerator is more than 0 and the liquid reserves are 0. in this case, The pool is at 100% utilization.
        if (numerator > 0 && liquidReserves == 0) return 1e18;

        // In all other cases, return the utilization ratio.
        return (numerator * 1e18) / liquidReserves;
    }

    /**
     * @notice Updates the address stored in this contract for the OptimisticOracle and the Store to the latest versions
     * set in the the Finder. We store these as local addresses to make relay methods more gas efficient.
     * @dev there is no risk of leaving this function public for anyone to call as in all cases we want the addresses
     * in this contract to map to the latest version in the Finder.
     */
    function syncWithFinderAddresses() public {
        FinderInterface finder = FinderInterface(bridgeAdmin.finder());

        optimisticOracle = SkinnyOptimisticOracleInterface(
            finder.getImplementationAddress(OracleInterfaces.SkinnyOptimisticOracle)
        );
        store = StoreInterface(finder.getImplementationAddress(OracleInterfaces.Store));
    }

    /**
     * @notice Updates the values of stored constants for the proposerBondPct, optimisticOracleLiveness and identifier
     * to that set in the bridge Admin. We store these as local variables to make the relay methods more gas efficient.
     * @dev there is no risk of leaving this function public for anyone to call as in all cases we want these values
     * in this contract to map to the latest version set in the BridgeAdmin.
     */
    function syncWithBridgeAdminParams() public {
        proposerBondPct = bridgeAdmin.proposerBondPct();
        optimisticOracleLiveness = bridgeAdmin.optimisticOracleLiveness();
        identifier = bridgeAdmin.identifier();
    }

    /************************************
     *          ADMIN FUNCTIONS         *
     ************************************/

    /**
     * @notice Enable the current bridge admin to transfer admin to to a new address.
     * @param _newAdmin Admin address of the new admin.
     */
    function changeAdmin(address _newAdmin) public override nonReentrant() {
        require(msg.sender == address(bridgeAdmin));
        bridgeAdmin = BridgeAdminInterface(_newAdmin);
        emit BridgePoolAdminTransferred(msg.sender, _newAdmin);
    }

    /************************************
     *           VIEW FUNCTIONS         *
     ************************************/

    /**
     * @notice Computes the current amount of unallocated fees that have accumulated from the previous time this the
     * contract was called.
     */
    function getAccumulatedFees() public view returns (uint256) {
        // UnallocatedLpFees := min(undistributedLpFees*lpFeeRatePerSecond*timeFromLastInteraction,undistributedLpFees)
        // The min acts to pay out all fees in the case the equation returns more than the remaining a fees.
        uint256 possibleUnpaidFees =
            (undistributedLpFees * lpFeeRatePerSecond * (getCurrentTime() - lastLpFeeUpdate)) / (1e18);
        return possibleUnpaidFees < undistributedLpFees ? possibleUnpaidFees : undistributedLpFees;
    }

    /**
     * @notice Returns ancillary data containing all relevant Relay data that voters can format into UTF8 and use to
     * determine if the relay is valid.
     * @dev Helpful method to test that ancillary data is constructed properly. We should consider removing if we don't
     * anticipate off-chain bots or users to call this method.
     * @param depositData Contains L2 deposit information used by off-chain validators to validate relay.
     * @param relayData Contains relay information used by off-chain validators to validate relay.
     * @return bytes New ancillary data that can be decoded into UTF8.
     */
    function getRelayAncillaryData(DepositData memory depositData, RelayData memory relayData)
        public
        view
        returns (bytes memory)
    {
        return AncillaryData.appendKeyValueBytes32("", "relayHash", _getRelayHash(depositData, relayData));
    }

    /**************************************
     *    INTERNAL & PRIVATE FUNCTIONS    *
     **************************************/

    // Note: this method is identical to `getRelayAncillaryData`, but it allows storage to be passed in, which saves
    // some gas (~3-4k) when called internally due to solidity not needing to copy the entire data structure and just
    // lazily read data when requested.
    function _getRelayAncillaryData(bytes32 relayHash) private pure returns (bytes memory) {
        return AncillaryData.appendKeyValueBytes32("", "relayHash", relayHash);
    }

    // Returns hash of unique relay and deposit event. This is added to the relay request's ancillary data.
    function _getRelayHash(DepositData memory depositData, RelayData memory relayData) private view returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    depositData.chainId,
                    depositData.depositId,
                    depositData.l1Recipient,
                    depositData.l2Sender,
                    depositData.amount,
                    depositData.slowRelayFeePct,
                    depositData.instantRelayFeePct,
                    depositData.quoteTimestamp,
                    relayData.relayId,
                    relayData.realizedLpFeePct,
                    address(l1Token)
                )
            );
    }

    // Return hash of relay data, which is stored in state and mapped to a deposit hash.
    function _getRelayDataHash(RelayData memory _relayData) private view returns (bytes32) {
        return keccak256(abi.encode(_relayData));
    }

    // Reverts if the stored relay data hash for `depositHash` does not match `_relayData`.
    function _validateRelayDataHash(bytes32 depositHash, RelayData memory _relayData) private view {
        require(
            relays[depositHash] == _getRelayDataHash(_relayData),
            "Hashed relay params do not match existing relay hash for deposit"
        );
    }

    // Return hash of unique instant relay and deposit event. This is stored in state and mapped to a deposit hash.
    function _getInstantRelayHash(bytes32 depositHash, RelayData memory _relayData) private view returns (bytes32) {
        // Only include parameters that affect the "correctness" of an instant relay. For example, the realized LP fee
        // % directly affects how many tokens the instant relayer needs to send to the user, whereas the address of the
        // instant relayer does not matter for determing whether an instant relay is "correct".
        return keccak256(abi.encode(depositHash, _relayData.realizedLpFeePct));
    }

    // Update internal fee counters by adding in any accumulated fees from the last time this logic was called.
    function updateAccumulatedLpFees() internal {
        // Calculate the unallocatedAccumulatedFees from the last time the contract was called.
        uint256 unallocatedAccumulatedFees = getAccumulatedFees();

        // Decrement the undistributedLpFees by the amount of accumulated fees.
        undistributedLpFees = undistributedLpFees - unallocatedAccumulatedFees;

        lastLpFeeUpdate = getCurrentTime();
    }

    // Allocate fees to the LPs by incrementing counters.
    function allocateLpFees(uint256 allocatedLpFees) internal {
        // Add to the total undistributed LP fees and the utilized reserves. Adding it to the utilized reserves acts to
        // track the fees while they are in transit.
        if (allocatedLpFees > 0) {
            undistributedLpFees += allocatedLpFees;
            utilizedReserves += int256(allocatedLpFees);
        }
    }

    function _getAmountFromPct(uint64 percent, uint256 amount) private pure returns (uint256) {
        return (percent * amount) / 1e18;
    }

    function _getProposerBond(uint256 amount) private view returns (uint256) {
        return _getAmountFromPct(proposerBondPct, amount);
    }

    function _getDepositHash(DepositData memory depositData) private view returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    depositData.chainId,
                    depositData.depositId,
                    depositData.l1Recipient,
                    depositData.l2Sender,
                    address(l1Token),
                    depositData.amount,
                    depositData.slowRelayFeePct,
                    depositData.instantRelayFeePct,
                    depositData.quoteTimestamp
                )
            );
    }

    // Proposes new price of True for relay event associated with `customAncillaryData` to optimistic oracle. If anyone
    // disagrees with the relay parameters and whether they map to an L2 deposit, they can dispute with the oracle.
    function _requestAndProposeOraclePriceRelay(
        uint256 amount,
        uint256 requestTimestamp,
        bytes memory customAncillaryData
    ) private {
        // Compute total proposal bond and pull from caller so that the OptimisticOracle can pull it from here.
        uint256 proposerBond = _getProposerBond(amount);
        uint256 finalFee = store.computeFinalFee(address(l1Token)).rawValue;
        uint256 totalBond =
            (uint256(bridgeAdmin.proposerBondPct()) * amount) / 1e18 + store.computeFinalFee(address(l1Token)).rawValue;

        l1Token.safeTransferFrom(msg.sender, address(this), totalBond);
        l1Token.safeApprove(address(optimisticOracle), totalBond);

        optimisticOracle.requestAndProposePriceFor(
            bridgeAdmin.identifier(),
            uint32(requestTimestamp),
            customAncillaryData,
            IERC20(l1Token),
            // Set reward to 0, since we'll settle proposer reward payouts directly from this contract after a relay
            // proposal has passed the challenge period.
            0,
            // Set the Optimistic oracle proposer bond for the price request.
            _getProposerBond(amount),
            // Set the Optimistic oracle liveness for the price request.
            uint256(bridgeAdmin.optimisticOracleLiveness()),
            // Caller is proposer.
            msg.sender,
            // Canonical value representing "True"; i.e. the proposed relay is valid.
            int256(1e18)
        );
    }
}
