// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

/**
 * @title OpaqueCredit
 * @notice Confidential onchain credit scoring — inputs stay encrypted, only the score is revealed.
 * @dev Zama Developer Program Mainnet Season 2 — Builder Track
 *      Built by Soch (https://x.com/soch_tweet)
 */
contract OpaqueCredit is ZamaEthereumConfig {

    struct CreditProfile {
        euint64 encWalletAgeDays;
        euint64 encTxCount;
        euint64 encRepaymentRatioBps;
        euint64 encCollateralRatioBps;
        euint64 encDefaultCount;
        euint64 encComputedScore;
        uint256 lastUpdated;
        bool    hasScore;
        uint64  publicScore;
        string  scoreTier;
    }

    mapping(address => CreditProfile) private profiles;

    address public owner;
    uint256 public totalProfiles;
    uint256 public totalDecryptions;

    uint64 public constant SCORE_MIN      = 300;
    uint64 public constant SCORE_POOR_MAX = 579;
    uint64 public constant SCORE_FAIR_MAX = 669;
    uint64 public constant SCORE_GOOD_MAX = 739;

    event ProfileSubmitted(address indexed user, uint256 timestamp);
    event ScoreRevealed   (address indexed user, uint64  score, string tier);

    constructor() {
        owner = msg.sender;
    }

    /**
     * @notice Submit encrypted financial signals.
     */
    function submitProfile(
        externalEuint64 encWalletAge,
        externalEuint64 encTxCount,
        externalEuint64 encRepaymentRatio,
        externalEuint64 encCollateralRatio,
        externalEuint64 encDefaultCount,
        bytes calldata  inputProof
    ) external {
        CreditProfile storage p = profiles[msg.sender];

        p.encWalletAgeDays      = FHE.fromExternal(encWalletAge,       inputProof);
        p.encTxCount            = FHE.fromExternal(encTxCount,         inputProof);
        p.encRepaymentRatioBps  = FHE.fromExternal(encRepaymentRatio,  inputProof);
        p.encCollateralRatioBps = FHE.fromExternal(encCollateralRatio, inputProof);
        p.encDefaultCount       = FHE.fromExternal(encDefaultCount,    inputProof);

        FHE.allowThis(p.encWalletAgeDays);
        FHE.allowThis(p.encTxCount);
        FHE.allowThis(p.encRepaymentRatioBps);
        FHE.allowThis(p.encCollateralRatioBps);
        FHE.allowThis(p.encDefaultCount);

        FHE.allow(p.encWalletAgeDays,      msg.sender);
        FHE.allow(p.encTxCount,            msg.sender);
        FHE.allow(p.encRepaymentRatioBps,  msg.sender);
        FHE.allow(p.encCollateralRatioBps, msg.sender);
        FHE.allow(p.encDefaultCount,       msg.sender);

        p.encComputedScore = _computeScore(
            p.encWalletAgeDays,
            p.encTxCount,
            p.encRepaymentRatioBps,
            p.encCollateralRatioBps,
            p.encDefaultCount
        );

        FHE.allowThis(p.encComputedScore);
        FHE.allow(p.encComputedScore, msg.sender);
        FHE.makePubliclyDecryptable(p.encComputedScore);

        p.lastUpdated = block.timestamp;
        p.hasScore    = false;

        if (p.publicScore == 0) totalProfiles++;

        emit ProfileSubmitted(msg.sender, block.timestamp);
    }

    /**
     * @notice Reveal score — called by the user after fetching the decryption proof off-chain.
     * @param clearScore         The decrypted score value
     * @param decryptionProof    Proof from the Zama KMS proving the decryption is valid
     */
    function revealScore(
        uint64       clearScore,
        bytes memory decryptionProof
    ) external {
        CreditProfile storage p = profiles[msg.sender];
        require(p.lastUpdated > 0, "No profile submitted yet");

        bytes32[] memory cts = new bytes32[](1);
        cts[0] = FHE.toBytes32(p.encComputedScore);

        bytes memory encodedClear = abi.encode(clearScore);
        FHE.checkSignatures(cts, encodedClear, decryptionProof);

        uint64 score = clearScore;
        if (score < SCORE_MIN) score = SCORE_MIN;
        if (score > 850)       score = 850;

        string memory tier;
        if      (score <= SCORE_POOR_MAX) tier = "Poor";
        else if (score <= SCORE_FAIR_MAX) tier = "Fair";
        else if (score <= SCORE_GOOD_MAX) tier = "Good";
        else                               tier = "Excellent";

        p.publicScore = score;
        p.scoreTier   = tier;
        p.hasScore    = true;
        totalDecryptions++;

        emit ScoreRevealed(msg.sender, score, tier);
    }

    /**
     * @dev Weighted score formula — all operations on encrypted values.
     */
    function _computeScore(
        euint64 walletAge,
        euint64 txCount,
        euint64 repaymentBps,
        euint64 collateralBps,
        euint64 defaultCount
    ) internal returns (euint64) {

        euint64 score = FHE.asEuint64(300);

        // Repayment — 35% (max 350 pts)
        euint64 repayPoints = FHE.min(
            FHE.div(FHE.mul(repaymentBps, 7), 200),
            FHE.asEuint64(350)
        );
        score = FHE.add(score, repayPoints);

        // Collateral — 30% (max 300 pts)
        euint64 collPoints = FHE.min(
            FHE.div(FHE.mul(FHE.min(collateralBps, FHE.asEuint64(10000)), 3), 100),
            FHE.asEuint64(300)
        );
        score = FHE.add(score, collPoints);

        // Wallet age — 15% (max 150 pts)
        euint64 agePoints = FHE.min(
            FHE.div(FHE.mul(FHE.min(walletAge, FHE.asEuint64(3650)), 3), 73),
            FHE.asEuint64(150)
        );
        score = FHE.add(score, agePoints);

        // Transaction activity — 10% (max 50 pts)
        euint64 txPoints = FHE.min(
            FHE.div(FHE.min(txCount, FHE.asEuint64(1000)), 20),
            FHE.asEuint64(50)
        );
        score = FHE.add(score, txPoints);

        // Default penalty (−20 pts each)
        euint64 penalty = FHE.mul(
            FHE.min(defaultCount, FHE.asEuint64(27)),
            20
        );
        ebool canSubtract = FHE.gt(score, penalty);
        score = FHE.select(
            canSubtract,
            FHE.sub(score, penalty),
            FHE.asEuint64(SCORE_MIN)
        );

        score = FHE.max(score, FHE.asEuint64(300));
        score = FHE.min(score, FHE.asEuint64(850));

        return score;
    }

    // ─── View functions ───────────────────────────────────────────────────────

    function getPublicScore(address user) external view returns (
        bool          hasScore,
        uint64        score,
        string memory tier,
        uint256       lastUpdated
    ) {
        CreditProfile storage p = profiles[user];
        return (p.hasScore, p.publicScore, p.scoreTier, p.lastUpdated);
    }

    function hasProfile(address user) external view returns (bool) {
        return profiles[user].lastUpdated > 0;
    }

    function getStats() external view returns (
        uint256 profileCount,
        uint256 decryptionCount
    ) {
        return (totalProfiles, totalDecryptions);
    }
}
