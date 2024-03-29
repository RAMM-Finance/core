pragma solidity ^0.8.16;

import {Auth} from "./auth/Auth.sol";
import {ERC4626} from "solmate/mixins/ERC4626.sol";

import {SafeCastLib} from "solmate/utils/SafeCastLib.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

import {ERC20} from "solmate/tokens/ERC20.sol";
import {Instrument} from "./instrument.sol";
import {PoolInstrument} from "../instruments/poolInstrument.sol";
import {Controller} from "../protocol/controller.sol";
import {MarketManager} from "../protocol/marketmanager.sol";
import "openzeppelin-contracts/utils/math/Math.sol";
import "forge-std/console.sol";

import {StorageHandler} from "../global/GlobalStorage.sol";
import "../global/types.sol";

contract Vault is ERC4626 {
    using SafeCastLib for uint256;
    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;

    /*///////////////////////////////////////////////////////////////
                                 CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 internal BASE_UNIT;
    uint256 public totalInstrumentHoldings; //total holdings deposited into all Instruments collateral
    ERC20 public immutable UNDERLYING;
    Controller private controller;
    MarketParameters default_params;
    string public description;

    ///// For Factory
    bool public onlyVerified;
    uint256 public r; //reputation ranking
    uint256 public asset_limit;
    uint256 public total_asset_limit;

    mapping(Instrument => InstrumentData) public instrument_data;
    // mapping(address => uint256) public  num_proposals;
    mapping(uint256 => Instrument) public Instruments; //marketID-> Instrument
    mapping(uint256 => bool) resolveBeforeMaturity;
    mapping(uint256 => ResolveVar) prepareResolveBlock;

    enum InstrumentType {
        CreditLine,
        CoveredCallShort,
        LendingPool,
        StraddleBuy,
        LiquidityProvision,
        Other
    }

    address public owner;

    constructor(
        address _UNDERLYING,
        address _controller,
        address _owner,
        bytes memory _configData,
        MarketParameters memory _default_params
    )
        ERC4626(
            ERC20(_UNDERLYING),
            string(
                abi.encodePacked("Ramm ", ERC20(_UNDERLYING).name(), " Vault")
            ),
            string(abi.encodePacked("RAMM", ERC20(_UNDERLYING).symbol()))
        )
    {
        (
            bool _onlyVerified,
            uint256 _r,
            uint256 _asset_limit,
            uint256 _total_asset_limit,
            string memory _description
        ) = abi.decode(_configData, (bool, uint256, uint256, uint256, string));
        description = _description;
        owner = _owner;
        UNDERLYING = ERC20(_UNDERLYING);
        require(UNDERLYING.decimals() == 18, "decimals");
        BASE_UNIT = 1e18;
        controller = Controller(_controller);
        //set_minting_conditions( _onlyVerified,  _r, _asset_limit, _total_asset_limit);
        onlyVerified = _onlyVerified;
        r = _r;
        asset_limit = _asset_limit;
        total_asset_limit = _total_asset_limit;
        default_params = _default_params;
    }

    function getInstrumentType(uint256 marketId) public view returns (uint256) {
        // return 0 if credit line //TODO
        return 0;
    }

    StorageHandler public Data;

    function setDataStore(address dataStore) public onlyController {
        Data = StorageHandler(dataStore);
    }

    function getInstrumentData(Instrument _instrument)
        public
        view
        returns (InstrumentData memory)
    {
        return instrument_data[_instrument];
    }

    function _onlyController() internal view {
        require(
            address(controller) == msg.sender ||
                msg.sender == owner ||
                address(this) == msg.sender,
            "is not controller"
        );
    }

    modifier onlyController() {
        _onlyController();
        _;
    }

    /// @notice amount is always in WAD, so need to convert if decimals mismatch
    function trusted_transfer(uint256 amount, address to)
        external
        onlyController
    {   console.log('resolving, bal', UNDERLYING.balanceOf(address(this))); 
        UNDERLYING.transfer(to, amount);
    }

    function modifyInstrumentHoldings(bool up, uint256 amount)
        external
        onlyController
    {
        if (up) totalInstrumentHoldings += amount;
        else totalInstrumentHoldings -= amount;
    }

    function balanceInUnderlying(address ad) external view returns (uint256) {
        return previewRedeem(balanceOf[ad]);
    }

    event InstrumentHarvest(
        address indexed instrument,
        uint256 totalInstrumentHoldings,
        uint256 instrument_balance,
        uint256 mag,
        bool sign
    ); //sign is direction of mag, + or -.

    /// @notice Harvest a trusted Instrument, records profit/loss
    // TODO instrument balance of underlying could be lower(ex. borrow), account for that
    function harvest(uint256 marketId) public {
        address instrument = address(fetchInstrument(marketId));

        require(
            instrument_data[Instrument(instrument)].trusted,
            "UNTRUSTED_Instrument"
        );
        InstrumentData storage data = instrument_data[Instrument(instrument)];

        uint256 balanceLastHarvest = data.balance;
        uint256 balanceThisHarvest;

        if (data.isPool) {
            (uint256 psu, , ) = Data.viewCurrentPricing(marketId);

            // Record how much does the shares this vault have translate to in underlying
            // 101
            balanceThisHarvest = data.poolData.sharesOwnedByVault.mulWadDown(
                psu
            );
        } else {
            balanceThisHarvest = Instrument(instrument).balanceOfUnderlying(
                address(instrument)
            );
        }

        uint256 oldTotalInstrumentHoldings = totalInstrumentHoldings;

        if (balanceLastHarvest == balanceThisHarvest) {
            return;
        }

        data.balance = balanceThisHarvest;

        uint256 delta;
        console.log("last and first", balanceLastHarvest, balanceThisHarvest);
        bool net_positive = balanceThisHarvest >= balanceLastHarvest;
        delta = net_positive
            ? balanceThisHarvest - balanceLastHarvest
            : balanceLastHarvest - balanceThisHarvest;
        totalInstrumentHoldings = net_positive
            ? oldTotalInstrumentHoldings + delta
            : oldTotalInstrumentHoldings - delta;

        emit InstrumentHarvest(
            instrument,
            totalInstrumentHoldings,
            balanceThisHarvest,
            delta,
            net_positive
        );
    }

    event InstrumentDeposit(
        uint256 indexed marketId,
        address indexed instrument,
        uint256 amount,
        bool isPool
    );

    /// @notice Deposit a specific amount of float into a trusted Instrument.
    /// Called when market is approved.
    /// Also has the role of granting a credit line to a credit-based Instrument like uncol.loans
    function depositIntoInstrument(
        uint256 marketId,
        uint256 underlyingAmount,
        bool isPerp,
        uint256 addedSeniorShares
    )
        public
        virtual
        onlyTrustedInstrument(fetchInstrument(marketId))
    //onlyManager
    {
        Instrument instrument = fetchInstrument(marketId);
        totalInstrumentHoldings += underlyingAmount;

        if (!isPerp) {
            // If is fixed instrument, add underlying amount supplied by the vault as balance

            instrument_data[instrument].balance += underlyingAmount;
            require(
                UNDERLYING.transfer(address(instrument), underlyingAmount),
                "DEPOSIT_FAILED"
            );
        } else {
            // Deposit to ERC4626 instrument

            UNDERLYING.approve(address(instrument), underlyingAmount);
            ERC4626(address(instrument)).deposit(
                underlyingAmount,
                address(this)
            );
            // uint shares = underlyingAmount.divWadDown(seniorUnderlyingPricing);
            // If is perp instrument, add shares minted by the vault
            // console.log('depositing shares', shares, underlyingAmount);
            instrument_data[instrument]
                .poolData
                .sharesOwnedByVault += addedSeniorShares;
            instrument_data[instrument].balance += underlyingAmount;
        }

        emit InstrumentDeposit(
            marketId,
            address(instrument),
            underlyingAmount,
            isPerp
        );
    }

    modifier onlyTrustedInstrument(Instrument instrument) {
        _onlyTrustedInstrument(instrument);
        _;
    }

    function _onlyTrustedInstrument(Instrument instrument) internal view {
        require(instrument_data[instrument].trusted, "UNTRUSTED Instrument");
    }

    event InstrumentWithdrawal(
        uint256 indexed marketId,
        address indexed instrument,
        uint256 amount
    );

    function withdrawAllFromInstrument(uint256 marketId)
        external
        onlyController
    {
        Instrument instrument = fetchInstrument(marketId);
        console.log(
            "howmuch",
            instrument.balanceOfUnderlying(address(instrument))
        );
        console.log("exchange rate", previewMint(1e18));
        instrument.redeemUnderlying(UNDERLYING.balanceOf(address(instrument)));
        console.log("exchange rate", previewMint(1e18));
    }

    /// @notice Withdraw a specific amount of underlying tokens from a Instrument.
    function withdrawFromInstrument(
        Instrument instrument,
        uint256 underlyingAmount,
        bool redeem
    ) internal virtual onlyTrustedInstrument(instrument) {
        // console.log('balance/underlying',instrument_data[instrument].balance,
        //   totalInstrumentHoldings,
        //   underlyingAmount );
        instrument_data[instrument].balance -= underlyingAmount;

        totalInstrumentHoldings -= underlyingAmount;

        if (redeem) instrument.redeemUnderlying(underlyingAmount);
            // require(
            //     ,
            //     "REDEEM_FAILED"
            // );
            

        emit InstrumentWithdrawal(
            instrument_data[instrument].marketId,
            address(instrument),
            underlyingAmount
        );
    }

    //TODO instrument balance should decrease to 0 and stay solvent
    //TODO can everyone redeem? does vault's instument share balance change when
    // mint-> redeem at different pjus?
    function withdrawFromPoolInstrument(
        uint256 marketId,
        uint256 instrumentPullAmount,
        address pushTo,
        uint256 underlyingAmount,
        uint256 withdrawnSeniorShares
    ) public virtual //onlyManager
    {
        // Send to withdrawer
        Instrument instrument = fetchInstrument(marketId);

        harvest(marketId);
        // console.log('withdrawn senior shares', underlyingAmount, psu.mulWadDown(withdrawnSeniorShares), previewMint(1e18));
        if (instrument.isLiquid(underlyingAmount + instrumentPullAmount)) {
            console.log(
                "wtf?",
                underlyingAmount + instrumentPullAmount,
                UNDERLYING.balanceOf(address(instrument))
            );
            ERC4626(address(instrument)).withdraw(
                underlyingAmount + instrumentPullAmount,
                address(this),
                address(this)
            );
        } else {
            ERC4626(address(instrument)).withdraw(
                UNDERLYING.balanceOf(address(instrument)),
                address(this),
                address(this)
            );
        }
        console.log("what the fucj", instrumentPullAmount, pushTo);
        UNDERLYING.transfer(pushTo, instrumentPullAmount);

        // Subtract instrument shares owned by vault
        // console.log('withdrawing shares',ERC4626(address(instrument)).previewWithdraw(underlyingAmount),
        //  instrument_data[instrument].poolData.sharesOwnedByVault);
        instrument_data[instrument]
            .poolData
            .sharesOwnedByVault -= withdrawnSeniorShares;

        // Finalize accounting logic
        withdrawFromInstrument(
            fetchInstrument(marketId),
            underlyingAmount,
            false
        );
    }

    event InstrumentTrusted(
        uint256 indexed marketId,
        address indexed instrument,
        uint256 principal,
        uint256 expectedYield,
        uint256 maturityDate
    );

    /// @notice Stores a Instrument as trusted when its approved
    function trustInstrument(
        uint256 marketId,
        ApprovalData memory data,
        bool isPool,
        uint256 addedSeniorShares //for perps, need inception price of instrument to record profit
    ) external virtual onlyController {
        instrument_data[fetchInstrument(marketId)].trusted = true;

        //Write to storage
        if (!isPool) {
            InstrumentData storage instrumentData = instrument_data[
                Instruments[marketId]
            ];
            instrumentData.principal = data.approved_principal;
            instrumentData.expectedYield = data.approved_yield;
            instrumentData.faceValue =
                data.approved_principal +
                data.approved_yield;
            depositIntoInstrument(
                marketId,
                data.approved_principal - data.managers_stake,
                false,
                0
            );

            // setMaturityDate(marketId);
            instrument_data[fetchInstrument(marketId)].maturityDate =
                instrument_data[fetchInstrument(marketId)].duration +
                block.timestamp;

            fetchInstrument(marketId).onMarketApproval(
                data.approved_principal,
                data.approved_yield
            );
        } else {
            instrument_data[Instruments[marketId]]
                .poolData
                .inceptionTime = block.timestamp;
            depositIntoInstrument(
                marketId,
                data.approved_principal - data.managers_stake,
                true,
                addedSeniorShares
            );
        }
        emit InstrumentTrusted(
            marketId,
            address(Instruments[marketId]),
            data.approved_principal,
            data.approved_yield,
            instrument_data[fetchInstrument(marketId)].maturityDate
        );
    }

    /// @notice fetches how much asset the instrument has in underlying.
    function instrumentAssetOracle(
        uint256 marketId,
        uint256 juniorSupply,
        uint256 seniorSupply
    ) public view returns (uint256) {
        // Default balance oracle
        ERC4626 instrument = ERC4626(address(Instruments[marketId]));
        return
            (juniorSupply + seniorSupply).mulWadDown(
                instrument.previewMint(BASE_UNIT)
            );
        //TODO custom oracle
    }

    /// @notice Stores a Instrument as untrusted
    // not needed?
    function distrustInstrument(Instrument instrument) external onlyController {
        instrument_data[instrument].trusted = false;
    }

    /// @notice returns true if Instrument is approved
    function isTrusted(Instrument instrument) public view returns (bool) {
        return instrument_data[instrument].trusted;
    }

    /// @notice Calculates the total amount of underlying tokens the Vault holds, excluding profit
    function totalAssets() public view override returns (uint256) {
        return totalInstrumentHoldings + totalFloat();
    }

    function utilizationRate() public view returns (uint256) {
        if (totalInstrumentHoldings == 0) return 0;
        return totalInstrumentHoldings.divWadDown(totalAssets());
    }

    function utilizationRateAfter(uint256 amount)
        public
        view
        returns (uint256)
    {
        return (totalInstrumentHoldings + amount).divWadDown(totalAssets());
    }

    function totalFloat() public view returns (uint256) {
        return UNDERLYING.balanceOf(address(this));
    }

    function fetchInstrument(uint256 marketId)
        public
        view
        returns (Instrument)
    {
        return Instruments[marketId];
    }

    function fetchInstrumentData(uint256 marketId)
        public
        view
        returns (InstrumentData memory)
    {
        return instrument_data[Instruments[marketId]];
    }

    function fetchPoolTrancheData(uint256 marketId)
        public
        view
        returns (
            uint256,
            uint256,
            uint256,
            uint256,
            uint256
        )
    {
        InstrumentData memory data = instrument_data[Instruments[marketId]];
        return (
            data.poolData.promisedReturn,
            data.poolData.inceptionTime,
            data.poolData.inceptionPrice,
            data.poolData.leverageFactor,
            data.poolData.managementFee
        );
    }

    event InstrumentRemoved(
        uint256 indexed marketId,
        address indexed instrumentAddress
    );

    /**
     called on market denial + removal, maybe no chekcs?
     */
    function removeInstrument(uint256 marketId) internal {
        InstrumentData storage data = instrument_data[Instruments[marketId]];
        require(data.marketId > 0, "instrument doesn't exist");
        delete instrument_data[Instruments[marketId]];
        delete Instruments[marketId];
        // emit event here;
        emit InstrumentRemoved(marketId, address(Instruments[marketId]));
    }

    // event ProposalAdded(InstrumentData data);
    /// @notice add instrument proposal created by the Utilizer
    /// @dev Instrument instance should be created before this is called
    /// need to add authorization
    function addProposal(InstrumentData memory data) external onlyController {
        if (!data.isPool) {
            require(data.principal > 0, "principal must be greater than 0");
            require(data.duration > 0, "duration must be greater than 0");
            require(data.faceValue > 0, "faceValue must be greater than 0");
            require(
                data.principal >= BASE_UNIT,
                "Needs to be in decimal format"
            );
            require(data.marketId > 0, "must be valid instrument");
        }
        // num_proposals[msg.sender] ++;
        // TODO indexed by id
        instrument_data[Instrument(data.instrument_address)] = data;

        Instruments[data.marketId] = Instrument(data.instrument_address);
        // emit ProposalAdded(data);
    }

    /// RESOLUTION LOGIC

    /// @notice function called when instrument resolves from within
    function pingMaturity(address instrument, bool premature) external {
        require(msg.sender == instrument || isTrusted(Instrument(instrument)));
        uint256 marketId = instrument_data[Instrument(instrument)].marketId;
        resolveInstrument1(marketId);
        resolveBeforeMaturity[marketId] = premature;
    }

    /// @notice returns true if instrument is ready to resolve (so resolveInstrument1 -> resolveInstrument2).
    function readyToResolve(uint256 marketId) public view returns (bool) {
        return Instruments[marketId].resolveCondition();
    }

    /// @notice RESOLVE FUNCTION #1
    /// Checks if instrument is ready to be resolved and locks capital.
    /// records blocknumber such that resolveInstrument is called after this function
    /// records balances+PnL of instrument
    /// @dev need to store internal balance that is used to calculate the redemption price
    // resolve fixed.
    function resolveInstrument1(uint256 marketId) public returns (bool imm) {
        Instrument _instrument = Instruments[marketId];

        require(
            msg.sender == address(_instrument) ||
            msg.sender == address(controller),
            "Not allowed"
        );
        require(isTrusted(_instrument), "Not trusted");

        // Should revert if can't be resolved
        require(_instrument.resolveCondition(), "!resolve");
        harvest(marketId);
        _instrument.storeInternalBalance();
        prepareResolveBlock[marketId] = ResolveVar(block.number, true);
        // Record profit/loss used for calculation of redemption price

    }

    //event InstrumentResolve(uint256 indexed marketId, uint256 instrumentBalance, bool atLoss, uint256 extraGain, uint256 totalLoss, bool prematureResolve);
    /// @notice RESOLVE FUNCTION #2
    /// @dev In cases of default, needs to be called AFTER the principal recouperation attempts
    /// like liquidations, auctions, etc such that the redemption price takes into account the maturity balance
    function resolveInstrument2(uint256 marketId)
        external
        onlyController
        returns (
            bool,
            uint256,
            uint256,
            bool
        )
    {
        Instrument _instrument = Instruments[marketId];
        ResolveVar memory rvar = prepareResolveBlock[marketId];
        require(_instrument.isLocked(), "Not Locked");
        // require(rvar.isPrepared && rvar.endBlock < block.number, "can't resolve");

        // uint256 bal = UNDERLYING.balanceOf(address(this));
        uint256 instrument_balance = _instrument.getMaturityBalance();

        bool prematureResolve = resolveBeforeMaturity[marketId];
        bool atLoss;
        uint256 total_loss;
        uint256 extra_gain;

        // If resolved at predetermined maturity date, loss is defined by
        // the event the instrument has paid out all its yield + principal
        if (!prematureResolve) {
          console.log("REP: ", instrument_balance, instrument_data[_instrument].faceValue);
          atLoss =
              instrument_balance < instrument_data[_instrument].faceValue;
          total_loss = atLoss
              ? instrument_data[_instrument].faceValue - instrument_balance
              : 0;
          extra_gain = !atLoss
              ? instrument_balance - instrument_data[_instrument].faceValue
              : 0;
        }
        // If resolved before predetermined maturity date, loss is defined by
        // the event the instrument has balance less then principal
        else {
            atLoss =
                instrument_balance < instrument_data[_instrument].principal;
            total_loss = atLoss
                ? instrument_data[_instrument].principal - instrument_balance
                : 0;
            extra_gain = !atLoss
                ? instrument_balance - instrument_data[_instrument].principal
                : 0;
        }

        withdrawFromInstrument(_instrument, instrument_balance, true);
        removeInstrument(instrument_data[_instrument].marketId);

        //emit InstrumentResolve(marketId, instrument_balance, atLoss, extra_gain, total_loss, prematureResolve);

        return (atLoss, extra_gain, total_loss, prematureResolve);
    }

    /// @notice when market resolves, send back pulled collateral from managers
    function repayDebt(address to, uint256 amount) external onlyController {
        UNDERLYING.transfer(to, amount);
    }

    event InstrumentDeny(uint256 indexed marketId);

    function denyInstrument(uint256 marketId) external onlyController {
        InstrumentData storage data = instrument_data[Instruments[marketId]];

        require(
            marketId > 0 && data.instrument_address != address(0),
            "invalid instrument"
        );

        require(!data.trusted, "can't deny approved instrument");
        emit InstrumentDeny(marketId);
        removeInstrument(marketId);
    }

    function instrumentApprovalCondition(uint256 marketId)
        external
        view
        returns (bool)
    {
        return Instruments[marketId].approvalCondition();
    }

    /// TODO
    function deduct_withdrawal_fees(uint256 amount) internal returns (uint256) {
        return amount;
    }

    /// @notice types of restrictions are:
    /// a) verified address b) reputation scores
    function receiver_conditions(address receiver) public view returns (bool) {
        return true;
    }

    function get_vault_params() public view returns (MarketParameters memory) {
        return default_params;
    }

    function beforeWithdraw(uint256 assets, uint256 shares)
        internal
        virtual
        override
    {
        require(enoughLiqudity(assets), "Not enough liqudity in vault");
    }

    /// @notice returns true if the vault has enough balance to withdraw or supply to new instrument
    /// (excluding those supplied to existing instruments)
    /// @dev for now this implies that the vault allows full utilization ratio, but the utilization ratio
    /// should be (soft)maxed and tunable by a parameter
    function enoughLiqudity(uint256 amounts) public view returns (bool) {
        return (UNDERLYING.balanceOf(address(this)) >= amounts);
    }

    /// @notice function that closes instrument prematurely
    function closeInstrument(uint256 marketId) external onlyController {
        Instrument instrument = fetchInstrument(marketId);

        // If instrument has non-underlying tokens, liquidate them first.
        // instrument.liquidateAllPositions();
    }

    function viewPrincipalAndYield(uint256 marketId)
        public
        view
        returns (uint256, uint256)
    {
        // InstrumentData memory data = instrument_data[Instruments[marketId]];
        return (
            instrument_data[Instruments[marketId]].principal,
            instrument_data[Instruments[marketId]].expectedYield
        );
    }

    function isValidator(address user, address instrument) external returns (bool) {
        return (controller.isValidator(instrument_data[Instrument(instrument)].marketId ,user));
    }

    /// @notice a minting restrictor is set for different vaults
    function mint(uint256 shares, address receiver)
        public
        virtual
        override
        returns (uint256 assets)
    {
        if (!receiver_conditions(receiver)) revert("Minting Restricted");
        assets = previewMint(shares); // No need to check for rounding error, previewMint rounds up.

        // Need to transfer before minting or ERC777s could reenter.
        asset.transferFrom(msg.sender, address(this), assets);

        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);

        afterDeposit(assets, shares);
    }

    /// @notice apply fee before withdrawing to prevent just minting before maturities and withdrawing after
    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) public virtual override returns (uint256 assets) {
        if (msg.sender != owner) {
            uint256 allowed = allowance[owner][msg.sender]; // Saves gas for limited approvals.

            if (allowed != type(uint256).max)
                allowance[owner][msg.sender] = allowed - shares;
        }

        // Check for rounding error since we round down in previewRedeem.
        require((assets = previewRedeem(shares)) != 0, "ZERO_ASSETS");

        beforeWithdraw(assets, shares);

        assets = deduct_withdrawal_fees(assets);

        _burn(owner, shares);

        emit Withdraw(msg.sender, receiver, owner, assets, shares);

        asset.transfer(receiver, assets);
    }

    struct localVars {
        uint256 promised_return;
        uint256 inceptionTime;
        uint256 inceptionPrice;
        uint256 leverageFactor;
        uint256 managementFee;
        uint256 srpPlusOne;
        uint256 totalAssetsHeldScaled;
        uint256 juniorSupply;
        uint256 seniorSupply;
        bool belowThreshold;
    }

    /// @notice get programmatic pricing of a pool based longZCB
    /// returns psu: price of senior(VT's share of investment) vs underlying
    /// returns pju: price of junior(longZCB) vs underlying
    // TODO inception price needs to be modifyable for changing senior returns
    function poolZCBValue(uint256 marketId)
        public
        view
        returns (
            uint256 psu,
            uint256 pju,
            uint256 levFactor
        )
    {
        //TODO should not tick during assessment
        localVars memory vars;

        (
            vars.promised_return,
            vars.inceptionTime,
            vars.inceptionPrice,
            vars.leverageFactor,
            vars.managementFee
        ) = fetchPoolTrancheData(marketId);
        levFactor = vars.leverageFactor;

        require(vars.inceptionPrice > 0, "0");

        // Get senior redemption price that increments per unit time
        vars.srpPlusOne = vars.inceptionPrice.mulWadDown(
            (BASE_UNIT + vars.promised_return).rpow(
                block.timestamp - vars.inceptionTime,
                BASE_UNIT
            )
        );

        // Get total assets held by the instrument
        vars.juniorSupply = controller.getTotalSupply(marketId);
        vars.seniorSupply = vars.juniorSupply.mulWadDown(vars.leverageFactor);
        vars.totalAssetsHeldScaled = instrumentAssetOracle(
            marketId,
            vars.juniorSupply,
            vars.seniorSupply
        ).mulWadDown(vars.inceptionPrice);

        if (vars.seniorSupply == 0)
            return (vars.srpPlusOne, vars.srpPlusOne, levFactor);

        // Check if all seniors can redeem
        if (
            vars.totalAssetsHeldScaled >=
            vars.srpPlusOne.mulWadDown(vars.seniorSupply)
        ) psu = vars.srpPlusOne;
        else {
            psu = vars.totalAssetsHeldScaled.divWadDown(vars.seniorSupply);
            vars.belowThreshold = true;
        }
        // should be 0 otherwise
        if (!vars.belowThreshold)
            pju = (vars.totalAssetsHeldScaled -
                vars.srpPlusOne.mulWadDown(vars.seniorSupply)).divWadDown(
                    vars.juniorSupply
                );
        uint256 pju_ = (BASE_UNIT + vars.leverageFactor).mulWadDown(
            previewMint(BASE_UNIT.mulWadDown(vars.inceptionPrice))
        ) - vars.srpPlusOne.mulWadDown(vars.leverageFactor);

        // assert(pju_ >= pju-10 || pju_ <= pju+10);
        // console.log('ok????');
    }
}
