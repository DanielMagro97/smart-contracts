pragma  solidity 0.5.11;

import "./WithdrawableV5.sol";
import "./UtilsV5.sol";
import "./ReentrancyGuard.sol";
import "./IKyberNetwork.sol";
import "./IKyberReserve.sol";
import "./IFeeHandler.sol";


////////////////////////////////////////////////////////////////////////////////////////////////////////
/// @title Kyber Network main contract
contract KyberTradeExecute is Withdrawable, Utils, IKyberNetwork, ReentrancyGuard {

    IFeeHandler     public feeHandlerContract;

    address         public kyberNetworkProxyContract;

    IKyberReserve[] public reserves;
    mapping(address=>uint) public reserveAddressToId;
    mapping(uint=>address[]) public reserveIdToAddresses;
    mapping(address=>bool) public isFeePayingReserve;
    mapping(address=>address) public reserveRebateWallet;

    constructor(address _admin) public
    Withdrawable(_admin)
    { /* empty body */ }

    event EtherReceival(address indexed sender, uint amount);

    function() external payable {
        emit EtherReceival(msg.sender, msg.value);
    }

    event AddReserveToNetwork (
        address indexed reserve,
        uint indexed reserveId,
        bool isFeePaying,
        address indexed rebateWallet,
        bool add);

    /// @notice can be called only by operator
    /// @dev add or deletes a reserve to/from the network.
    /// @param reserve The reserve address.
    function addReserve(address reserve, uint reserveId, bool isFeePaying, address wallet) public onlyOperator returns(bool) {
        require(reserveIdToAddresses[reserveId].length == 0);
        require(reserveAddressToId[reserve] == uint(0));

        reserveAddressToId[reserve] = reserveId;

        reserveIdToAddresses[reserveId][0] = reserve;
        isFeePayingReserve[reserve] = isFeePaying;

        reserves.push(IKyberReserve(reserve));

        reserveRebateWallet[reserve] = wallet;

        emit AddReserveToNetwork(reserve, reserveId, isFeePaying, wallet, true);

        return true;
    }

    event KyberProxySet(address proxy, address sender);

    function setKyberProxy(address networkProxy) public onlyAdmin {
        require(networkProxy != address(0));
        kyberNetworkProxyContract = networkProxy;
        emit KyberProxySet(kyberNetworkProxyContract, msg.sender);
    }
    /// @notice use token address ETH_TOKEN_ADDRESS for ether
    /// @dev do one trade with a reserve
    /// @param src Src token
    /// @param amount amount of src tokens
    /// @param dest   Destination token
    /// @param destAddress Address to send tokens to
    /// @return true if trade is successful
    function doReserveTrades(
        IERC20 src,
        uint amount,
        IERC20 dest,
        address payable destAddress,
        IKyberReserve[] calldata reserveAddresses,
        uint[] calldata reserveSplits,
        uint[] calldata reserveRates,
        uint[] calldata reserveBits,
        uint expectedDestAmount
    )
        external
        returns(bool)
    {
        require(msg.sender == kyberNetworkProxyContract);
        
        if (src == dest) {
            //this is for a "fake" trade when both src and dest are ethers.
            if (destAddress != (address(this)))
                destAddress.transfer(amount);
            return true;
        }

        reserveBits;
        reserveRates;
        
        uint callValue;
        uint srcAmountSoFar;

        for(uint i = 0; i < reserveAddresses.length; i++) {
            uint splitAmountSrc = i == (reserveAddresses.length - 1) ? (amount - srcAmountSoFar) : reserveSplits[i] * amount / BPS;
            srcAmountSoFar += splitAmountSrc;
            callValue = (src == ETH_TOKEN_ADDRESS)? splitAmountSrc : 0;

            // reserve sends tokens/eth to network. network sends it to destination
            // todo: if reserve supports returning destTokens call accordingly
            require(reserveAddresses[i].trade.value(callValue)(src, splitAmountSrc, dest, address(this), 
                reserveRates[i], true));
        }

        if (destAddress != address(this)) {
            //for token to token dest address is network. and Ether / token already here...
            if (dest == ETH_TOKEN_ADDRESS) {
                destAddress.transfer(expectedDestAmount);
            } else {
                require(dest.transfer(destAddress, expectedDestAmount));
            }
        }

        return true;
    }

    /// when user sets max dest amount we could have too many source tokens == change. so we send it back to user.
    function handleChange (IERC20 src, uint srcAmount, uint requiredSrcAmount, address payable trader) internal returns (bool) {

        if (requiredSrcAmount < srcAmount) {
            //if there is "change" send back to trader
            if (src == ETH_TOKEN_ADDRESS) {
                trader.transfer(srcAmount - requiredSrcAmount);
            } else {
                require(src.transfer(trader, (srcAmount - requiredSrcAmount)));
            }
        }

        return true;
    }
}
