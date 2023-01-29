pragma solidity ^0.8.16;

import {Controller} from "./controller.sol";
import {MarketManager} from "./marketmanager.sol";
import {ReputationManager} from "./reputationmanager.sol";
import {SyntheticZCBPool} from "../bonds/synthetic.sol";
import {config} from "../utils/helpers.sol";
import {ERC4626} from "../vaults/mixins/ERC4626.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {Vault} from "../vaults/vault.sol";

contract ValidatorManager {
    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;
    Controller private controller;
    ReputationManager private reputationManager;
    MarketManager private marketManager;

    modifier onlyController () {
        require(msg.sender == address(controller), "not controller");
        _;
    }

     /*----Validator Logic----*/
    struct ValidatorData {
        mapping(address => uint256) sales; // amount of zcb bought per validator
        mapping(address => bool) staked; // true if address has staked vt (approved)
        mapping(address => bool) resolved; // true if address has voted to resolve the market
        address[] validators;
        uint256 val_cap; // total zcb validators can buy at a discount
        uint256 avg_price; //price the validators can buy zcb at a discount
        bool requested; // true if already requested random numbers from array.
        uint256 totalSales; // total amount of zcb bought;
        uint256 totalStaked; // total amount of vault token staked.
        uint256 numApproved;
        uint256 initialStake; // amount staked
        uint256 finalStake; // amount of stake recoverable post resolve
        uint256 numResolved; // number of validators calling resolve on early resolution.
    }

    mapping(uint256 => uint256) requestToMarketId;
    mapping(uint256 => ValidatorData) public validator_data;
    
    constructor (
        address _controller,
        address _marketManager,
        address _reputationManager
        ) {
        controller = Controller(_controller);
        reputationManager = ReputationManager(_reputationManager);
        marketManager = MarketManager(_marketManager);
    }

    function validatorSetup(
        uint256 marketId,
        uint256 principal,
        bool isPool
    ) external onlyController {
        require(principal != 0, "0 principal");
        _getValidators(marketId);
        _setValidatorCap(marketId, principal, isPool);
        _setValidatorStake(marketId, principal);
    }

    function _getValidators(uint256 marketId) public {
        // retrieve traders that meet requirement.
        // address instrument = market_data[marketId].instrument_address;
        (,address utilizer) = controller.market_data(marketId);

        (uint256 N, , , , , uint256 r, , ) = marketManager.parameters(marketId);
        address[] memory selected = reputationManager.filterTraders(
            r,
            utilizer
        );

        // if there are not enough traders, set validators to all selected traders.
        if (selected.length <= N) {
            validator_data[marketId].validators = selected;

            if (selected.length < N) {
                revert("not enough rated traders");
            }

            return;
        }

        validator_data[marketId].requested = true;

        uint256 _requestId = 1;
        // uint256 _requestId = COORDINATOR.requestRandomWords(
        //   keyHash,
        //   subscriptionId,
        //   requestConfirmations,
        //   callbackGasLimit,
        //   uint32(parameters[marketId].N)
        // );

        requestToMarketId[_requestId] = marketId;
    }

    function _setValidatorCap(
        uint256 marketId,
        uint256 principal,
        bool isPool //??
    ) internal {
        SyntheticZCBPool bondingPool = marketManager.getPool(marketId);
        (, uint256 sigma, , , , , , ) = marketManager.parameters(marketId);
        require(config.isInWad(sigma) && config.isInWad(principal), "paramERR");
        ValidatorData storage valdata = validator_data[marketId];

        uint256 valColCap = (sigma.mulWadDown(principal));

        // Get how much ZCB validators need to buy in total, which needs to be filled for the market to be approved
        uint256 discount_cap = bondingPool.discount_cap();
        uint256 avgPrice = valColCap.divWadDown(discount_cap);

        valdata.val_cap = discount_cap;
        valdata.avg_price = avgPrice;
    }

     /**
   @notice sets the amount of vt staked by a single validator for a specific market
   @dev steak should be between 1-0 wad.
   */
    function _setValidatorStake(uint256 marketId, uint256 principal) internal {
        //get vault
        uint256 vaultId = controller.id_parent(marketId);
        Vault vault = controller.vaults(vaultId);
        // ERC4626 vault = ERC4626(vaults[id_parent[marketId]]);
        uint256 shares = vault.convertToShares(principal);
        (, , , , , , , uint256 steak) = marketManager.parameters(marketId);
        validator_data[marketId].initialStake = steak.mulWadDown(shares);
    }

    function deniedValidator(uint256 marketId, address validator)
        external
        onlyController
        returns (uint256 collateral_amount)
    {
        //??? is this correct
        collateral_amount = validator_data[marketId]
            .sales[validator]
            .mulWadDown(validator_data[marketId].avg_price);
        delete validator_data[marketId].sales[validator];
    }

    function redeemValidator(uint256 marketId, address validator)
        external
        onlyController
    {
        delete validator_data[marketId].sales[validator];
    }

    function getValidatorRequiredCollateral(uint256 marketId)
        public
        view
        returns (uint256)
    {
        uint256 val_cap = validator_data[marketId].val_cap;
        (uint256 N, , , , , , , ) = marketManager.parameters(marketId);
        uint256 zcb_for_sale = val_cap / N;
        return zcb_for_sale.mulWadDown(validator_data[marketId].avg_price);
    }

    function unlockValidatorStake(uint256 marketId, address validator) onlyController external {
        require(isValidator(marketId, validator), "!validator");
        require(validator_data[marketId].staked[validator], "!stake");
        (bool duringMarketAssessment, , , , , ) = marketManager
            .restriction_data(marketId);

        // market early denial, no loss.
        uint256 vaultId = controller.id_parent(marketId);
        Vault vault = controller.vaults(vaultId);
        if (duringMarketAssessment) {
            ERC20(controller.getVaultAd(marketId)).safeTransfer(
                validator,
                validator_data[marketId].initialStake
            );
            validator_data[marketId].totalStaked -= validator_data[marketId]
                .initialStake;
        } else {
            // market resolved.
            ERC20(controller.getVaultAd(marketId)).safeTransfer(
                validator,
                validator_data[marketId].finalStake
            );
            validator_data[marketId].totalStaked -= validator_data[marketId]
                .finalStake;
        }

        validator_data[marketId].staked[validator] = false;
    }

     function updateValidatorStake(
        uint256 marketId,
        uint256 principal,
        uint256 principal_loss
    ) public onlyController {
        if (principal_loss == 0) {
            validator_data[marketId].finalStake = validator_data[marketId]
                .initialStake;
            return;
        }

        uint256 vaultId = controller.id_parent(marketId);
        Vault vault = controller.vaults(vaultId);
        uint256 p_shares = vault.convertToShares(principal);
        uint256 p_loss_shares = vault.convertToShares(principal_loss);

        uint256 totalStaked = validator_data[marketId].totalStaked;
        uint256 newTotal = totalStaked /
            2 +
            (p_shares - p_loss_shares).divWadDown(p_shares).mulWadDown(
                totalStaked / 2
            );

        ERC4626(controller.getVaultAd(marketId)).burn(totalStaked - newTotal);
        validator_data[marketId].totalStaked = newTotal;

        validator_data[marketId].finalStake =
            newTotal /
            validator_data[marketId].validators.length;
    }

    function validatorResolve(uint256 marketId, address validator) onlyController external {
        require(isValidator(marketId, validator), "!val");
        require(!validator_data[marketId].resolved[validator], "voted");

        validator_data[marketId].resolved[validator] = true;
        validator_data[marketId].numResolved++;
    }

    function isValidator(uint256 marketId, address user)
        public
        view
        returns (bool)
    {
        address[] storage _validators = validator_data[marketId].validators;
        for (uint256 i = 0; i < _validators.length; i++) {
            if (_validators[i] == user) {
                return true;
            }
        }
        return false;
    }

    function validatorApprove(uint256 marketId, address validator) external returns (uint256 collateral_required, uint256 zcb_for_sale) {
        require(isValidator(marketId, validator), "!Val");
        require(controller.marketCondition(marketId), "!condition");

        ValidatorData storage valdata = validator_data[marketId];
        require(!valdata.staked[validator], "!staked");

        // staking logic, TODO optional since will throw error on transfer.
        // require(ERC20(getVaultAd(marketId)).balanceOf(validator) >= valdata.initialStake, "not enough tokens to stake");

        // staked vault tokens go to controller
        ERC20(controller.getVaultAd(marketId)).safeTransferFrom(
            validator,
            address(this),
            valdata.initialStake
        );

        valdata.totalStaked += valdata.initialStake;
        valdata.staked[validator] = true;

        (uint256 N, , , , , , , ) = marketManager.parameters(marketId);
        zcb_for_sale = valdata.val_cap / N;
        collateral_required = zcb_for_sale.mulWadDown(
            valdata.avg_price
        );

        require(valdata.sales[validator] <= zcb_for_sale, "approved");

        valdata.sales[validator] += zcb_for_sale;
        valdata.totalSales += (zcb_for_sale + 1); //since division rounds down ??
        valdata.numApproved += 1;

        // marketManager actions on validatorApprove, transfers collateral to marketManager.
        // marketManager.validatorApprove(
        //     marketId,
        //     collateral_required,
        //     zcb_for_sale,
        //     validator
        // );

        // Last validator pays more gas, is fair because earlier validators are more uncertain
        if (controller.approvalCondition(marketId)) {
            controller.approveMarket(marketId);
            // marketManager.approveMarket(marketId); // For market to go to a post assessment stage there always needs to be a lower bound set
        }
    }

    function approvalCondition(uint256 marketId) public view returns (bool) {
        return (validator_data[marketId].totalSales >=
            validator_data[marketId].val_cap &&
            validator_data[marketId].validators.length ==
            validator_data[marketId].numApproved);
    }


    function getValidatorPrice(uint256 marketId) public view returns (uint256) {
        return validator_data[marketId].avg_price;
    }

    function getValidatorCap(uint256 marketId) public view returns (uint256) {
        return validator_data[marketId].val_cap;
    }

    function viewValidators(uint256 marketId)
        public
        view
        returns (address[] memory)
    {
        return validator_data[marketId].validators;
    }

    function fulfillRandomWords(
        uint256 requestId,
        uint256[] memory randomWords //internal
    ) external onlyController
    {
        uint256 marketId = requestToMarketId[requestId];
        (uint256 N, , , , , uint256 r, , ) = marketManager.parameters(marketId);

        assert(randomWords.length == N);

        // address instrument = market_data[marketId].instrument_address;
        (,address utilizer) = controller.market_data(marketId);

        address[] memory temp = reputationManager.filterTraders(r, utilizer);
        uint256 length = temp.length;

        // get validators
        for (uint8 i = 0; i < N; i++) {
            uint256 j = _weightedRetrieve(temp, length, randomWords[i]);
            validator_data[marketId].validators.push(temp[j]);
            temp[j] = temp[length - 1];
            length--;
        }
    }

    function _weightedRetrieve(
        address[] memory group,
        uint256 length,
        uint256 randomWord
    ) internal view returns (uint256) {
        uint256 sum_weights;

        for (uint8 i = 0; i < length; i++) {
            sum_weights += controller.getTraderScore(group[i]); //repToken.getReputationScore(group[i]);
        }

        uint256 tmp = randomWord % sum_weights;

        for (uint8 i = 0; i < length; i++) {
            uint256 wt = controller.getTraderScore(group[i]);
            if (tmp < wt) {
                return i;
            }
            unchecked {
                tmp -= wt;
            }
        }
    }

    function resolveCondition(uint256 marketId) public view returns (bool) {
        return (validator_data[marketId].numResolved ==
            validator_data[marketId].validators.length);
    }

    function hasApproved(uint256 marketId, address validator)
        public
        view
        returns (bool)
    {
        return validator_data[marketId].staked[validator];
    }

    function getNumApproved(uint256 marketId) public view returns (uint256) {
        //return validatorManager.getNumApproved(marketId);
        return validator_data[marketId].numApproved;
    }

    function getNumResolved(uint256 marketId) public view returns (uint256) {
        //return validatorManager.getNumResolved(marketId);
        return validator_data[marketId].numResolved;
    }

    function getTotalStaked(uint256 marketId) public view returns (uint256) {
        // return validatorManager.getTotalStaked(marketId);
        return validator_data[marketId].totalStaked;
    }

    function getTotalValidatorSales(uint256 marketId)
        public
        view
        returns (uint256)
    {
        // return validatorManager.getTotalValidatorSales(marketId);
        return validator_data[marketId].totalSales;
    }

    function getInitialStake(uint256 marketId) public view returns (uint256) {
        //return validatorManager.getInitialStake(marketId);
        return validator_data[marketId].initialStake;
    }

    function getFinalStake(uint256 marketId) public view returns (uint256) {
        //return validatorManager.getFinalStake(marketId);
        return validator_data[marketId].finalStake;
    }
}