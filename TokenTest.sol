// SPDX-License-Identifier: MIT

pragma solidity ^0.8.4;

import "@openzeppelin/contracts/token/ERC20/presets/ERC20PresetMinterPauser.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/access/AccessControlEnumerable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Context.sol";
import "@openzeppelin/contracts/access/IAccessControlEnumerable.sol";
import "@openzeppelin/contracts/access/IAccessControl.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";


interface IERC721 {
    function balanceOf(address _user) external view returns (uint256);
}

contract WagmiToken is ERC20PresetMinterPauser {
    using SafeMath for uint256;

    IERC721 public nftContract;

    uint256 public constant INITIAL_REWARD = 100 ether;
    uint256 public constant REWARD_RATE = 10 ether;
    uint256 public constant SECONDARY_REWARD_RATE = 5 ether;
    // Monday, April 1, 2032 0:00:00
    uint256 public constant REWARD_END = 1964390400;

    mapping(address => uint256) public rewards;
    mapping(address => uint256) public lastUpdate;
    mapping(address => IERC721) public secondaryContracts;
    address[] public secondaryContractsAddresses;

    event WagmiClaimed(address indexed account, uint256 reward);
    event WagmiSpent(address indexed account, uint256 amount);

    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");

    constructor(address _nftContract)
        ERC20PresetMinterPauser("Wagmi Token", "WAG")
    {
        grantRole(BURNER_ROLE, msg.sender);
        setContract(_nftContract);
    }

    function setContract(address _contract) public {
        require(hasRole(DEFAULT_ADMIN_ROLE, _msgSender()), "Admin only");
        nftContract = IERC721(_contract);
        grantRole(BURNER_ROLE, _contract);
    }

    function addSecondaryContract(address _contract) public {
        require(hasRole(DEFAULT_ADMIN_ROLE, _msgSender()), "Admin only");
        secondaryContracts[_contract] = IERC721(_contract);
        secondaryContractsAddresses.push(_contract);
        grantRole(BURNER_ROLE, _contract);
    }

    function removeSecondaryContract(address _contract) public {
        require(hasRole(DEFAULT_ADMIN_ROLE, _msgSender()), "Admin only");
        delete secondaryContracts[_contract];
        uint256 index = 0;
        while (secondaryContractsAddresses[index] != _contract) {
            index++;
        }
        secondaryContractsAddresses[index] = secondaryContractsAddresses[
            secondaryContractsAddresses.length - 1
        ];
        secondaryContractsAddresses.pop();
        revokeRole(BURNER_ROLE, _contract);
    }

    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function updateRewardOnMint(address _to, uint256 _amount) external {
        require(msg.sender == address(nftContract), "Not allowed");
        uint256 time = min(block.timestamp, REWARD_END);
        uint256 timerUser = lastUpdate[_to];
        if (timerUser > 0)
            rewards[_to] = rewards[_to].add(
                nftContract
                    .balanceOf(_to)
                    .mul(REWARD_RATE.mul((time.sub(timerUser))))
                    .div(86400)
                    .add(_amount.mul(INITIAL_REWARD))
            );
        else rewards[_to] = rewards[_to].add(_amount.mul(INITIAL_REWARD));
        lastUpdate[_to] = time;
    }

    function updateReward(address _from, address _to) external {
        require(
            msg.sender == address(nftContract) ||
                abi.encodePacked(secondaryContracts[msg.sender]).length > 0,
            "Invalid Contract"
        );
        uint256 time = min(block.timestamp, REWARD_END);
        if (_from != address(0)) {
            uint256 timerFrom = lastUpdate[_from];
            if (timerFrom > 0) {
                rewards[_from] += getPendingReward(_from);
            }
            lastUpdate[_from] = lastUpdate[_from] < REWARD_END
                ? time
                : REWARD_END;
        }

        if (_to != address(0)) {
            uint256 timerTo = lastUpdate[_to];
            if (timerTo > 0) {
                rewards[_to] += getPendingReward(_to);
            }
            lastUpdate[_to] = lastUpdate[_to] < REWARD_END ? time : REWARD_END;
        }
    }

    function getReward(address _to) external {
        require(msg.sender == address(nftContract), "Not allowed");
        uint256 reward = rewards[_to];
        if (reward > 0) {
            rewards[_to] = 0;
            _mint(_to, reward);
            emit WagmiClaimed(_to, reward);
        }
    }

    function getTotalClaimable(address _account)
        external
        view
        returns (uint256)
    {
        return rewards[_account] + getPendingReward(_account);
    }

    function getPendingReward(address _account)
        internal
        view
        returns (uint256)
    {
        uint256 time = min(block.timestamp, REWARD_END);
        uint256 secondary = 0;
        if (secondaryContractsAddresses.length > 0) {
            for (uint256 i = 0; i < secondaryContractsAddresses.length; i++) {
                secondary = secondaryContracts[secondaryContractsAddresses[i]]
                    .balanceOf(_account)
                    .mul(
                        SECONDARY_REWARD_RATE.mul(
                            (time.sub(lastUpdate[_account]))
                        )
                    )
                    .div(86400)
                    .add(secondary);
            }
        }

        return
            nftContract
                .balanceOf(_account)
                .mul(REWARD_RATE.mul((time.sub(lastUpdate[_account]))))
                .div(86400)
                .add(secondary);
    }

    function burn(uint256 value) public override {
        require(
            hasRole(BURNER_ROLE, msg.sender),
            "Must have burner role to burn"
        );
        super._burn(msg.sender, value);
    }

    function spend(address _from, uint256 _amount) external {
        require(
            hasRole(BURNER_ROLE, msg.sender),
            "Must have burner role to spend"
        );
        super._burn(_from, _amount);
        emit WagmiSpent(_from, _amount);
    }
}
