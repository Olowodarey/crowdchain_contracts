// SPDX-License-Identifier: MIT
// Compatible with OpenZeppelin Contracts for Cairo ^1.0.0

const PAUSER_ROLE: felt252 = selector!("PAUSER_ROLE");
const UPGRADER_ROLE: felt252 = selector!("UPGRADER_ROLE");
const ADMIN_ROLE: felt252 = selector!("ADMIN_ROLE");

#[starknet::contract]
pub mod Crowdchain {
    use core::array::ArrayTrait;
    use core::num::traits::Zero;
    use core::option::Option;
    #[event]
    use crowdchain_contracts::events::CrowdchainEvent::{
        CampaignCreated, CampaignPaused, CampaignUnpaused, CampaignStatusUpdated,
        ContributionProcessed // add to the list when needed
    };
    use crowdchain_contracts::interfaces::ICrowdchain::ICrowdchain;
    use crowdchain_contracts::structs::Structs::{CamapaignStats, Campaign};
    use openzeppelin::access::accesscontrol::{AccessControlComponent, DEFAULT_ADMIN_ROLE};
    use openzeppelin::introspection::src5::SRC5Component;
    use openzeppelin::security::pausable::PausableComponent;
    use openzeppelin::token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
    use openzeppelin::upgrades::UpgradeableComponent;
    use openzeppelin::upgrades::interface::IUpgradeable;
    use starknet::storage::{
        Map, StorageMapReadAccess, StoragePathEntry, StoragePointerReadAccess,
        StoragePointerWriteAccess, Vec,
    };
    use starknet::{
        ClassHash, ContractAddress, get_block_timestamp, get_caller_address, get_contract_address,
    };
    use super::{ADMIN_ROLE, PAUSER_ROLE, UPGRADER_ROLE};


    component!(path: PausableComponent, storage: pausable, event: PausableEvent);
    component!(path: AccessControlComponent, storage: accesscontrol, event: AccessControlEvent);
    component!(path: SRC5Component, storage: src5, event: SRC5Event);
    component!(path: UpgradeableComponent, storage: upgradeable, event: UpgradeableEvent);

    // External
    #[abi(embed_v0)]
    impl PausableImpl = PausableComponent::PausableImpl<ContractState>;
    #[abi(embed_v0)]
    impl AccessControlMixinImpl =
        AccessControlComponent::AccessControlMixinImpl<ContractState>;

    // Internal
    impl PausableInternalImpl = PausableComponent::InternalImpl<ContractState>;
    impl AccessControlInternalImpl = AccessControlComponent::InternalImpl<ContractState>;
    impl UpgradeableInternalImpl = UpgradeableComponent::InternalImpl<ContractState>;

    #[storage]
    struct Storage {
        #[substorage(v0)]
        pausable: PausableComponent::Storage,
        #[substorage(v0)]
        accesscontrol: AccessControlComponent::Storage,
        #[substorage(v0)]
        src5: SRC5Component::Storage,
        #[substorage(v0)]
        upgradeable: UpgradeableComponent::Storage,
        approved_creators: Map<ContractAddress, bool>,
        campaigns: Map<u64, Campaign>,
        campaign_status: Map<u64, CampaignStatus>,
        campaign_supporters: Map<(u64, ContractAddress), bool>,
        campaign_supporter_count: Map<u64, u64>,
        campaign_created_at: Map<u64, u64>,
        campaign_updated_at: Map<u64, u64>,
        campaign_paused_at: Map<u64, u64>,
        campaign_completed_at: Map<u64, u64>,
        campaign_counter: u64,
        campaign_ids: Vec<u64>,
        // Admin tracking system
        owner: ContractAddress, // Store owner address
        admins: Map<ContractAddress, bool>, // Store admin addresses
        admin_addresses: Map<u32, ContractAddress>, // Store admin addresses by index
        admin_count: u32, // Keep track of total admins
        // Contribution storage
        contributions: Map<(u64, ContractAddress), u256>,
        campaign_total_contributions: Map<u64, u256>,
        user_total_contributions: Map<ContractAddress, u256>,
    }


    #[derive(Copy, Drop, Serde, PartialEq, starknet::Store)]
    pub enum CampaignStatus {
        Active,
        Paused,
        Completed,
        #[default]
        Unknown,
    }


    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        #[flat]
        PausableEvent: PausableComponent::Event,
        #[flat]
        AccessControlEvent: AccessControlComponent::Event,
        #[flat]
        SRC5Event: SRC5Component::Event,
        #[flat]
        UpgradeableEvent: UpgradeableComponent::Event,
        Created: CampaignCreated,
        StatusUpdated: CampaignStatusUpdated,
        HoldCampaign: CampaignPaused,
        UnholdCampaign: CampaignUnpaused,
        ContributionProcessed: ContributionProcessed,
        // Add Events after importing it above
    }

    #[constructor]
    fn constructor(ref self: ContractState, owner: ContractAddress) {
        self.accesscontrol.initializer();

        // Grant OpenZeppelin roles to owner
        self.accesscontrol._grant_role(DEFAULT_ADMIN_ROLE, owner);
        self.accesscontrol._grant_role(PAUSER_ROLE, owner);
        self.accesscontrol._grant_role(UPGRADER_ROLE, owner);

        // Initialize admin tracking system
        self.owner.write(owner);
        // Owner is not counted as an admin in the admin tracking system
        self.admin_count.write(0);
    }

    #[generate_trait]
    #[abi(per_item)]
    impl ExternalImpl of ExternalTrait {
        #[external(v0)]
        fn pause(ref self: ContractState) {
            self.accesscontrol.assert_only_role(PAUSER_ROLE);
            self.pausable.pause();
        }

        #[external(v0)]
        fn unpause(ref self: ContractState) {
            self.accesscontrol.assert_only_role(PAUSER_ROLE);
            self.pausable.unpause();
        }
    }

    //
    // Upgradeable
    //

    #[abi(embed_v0)]
    impl UpgradeableImpl of IUpgradeable<ContractState> {
        fn upgrade(ref self: ContractState, new_class_hash: ClassHash) {
            self.accesscontrol.assert_only_role(UPGRADER_ROLE);
            self.upgradeable.upgrade(new_class_hash);
        }
    }

    #[abi(embed_v0)]
    impl Crowdchain of ICrowdchain<ContractState> {
        fn create_campaign(
            ref self: ContractState,
            creator: ContractAddress,
            title: ByteArray,
            description: ByteArray,
            goal: u256,
            image_url: ByteArray,
        ) -> u64 {
            // Check if contract is paused
            self.pausable.assert_not_paused();
            assert(!creator.is_zero(), 'Creator cannot be the 0 address');
            let is_approved = self.approved_creators.read(creator);
            assert(is_approved, 'Creator not approved');

            let new_campaign_id = self.campaign_counter.read() + 1;
            let current_timestamp = get_block_timestamp();

            // Create the full Campaign struct with all details
            let campaign = Campaign {
                id: new_campaign_id,
                creator: creator,
                title: title,
                description: description,
                goal: goal,
                amount_raised: 0_u256,
                start_timestamp: current_timestamp,
                end_timestamp: 0_u64, // Can be set later
                is_active: true,
                contributors_count: 0_u64,
                rewards_issued: false,
            };

            // Store the campaign and tracking data
            self.campaigns.entry(new_campaign_id).write(campaign);
            self.campaign_status.entry(new_campaign_id).write(CampaignStatus::Active);
            self.campaign_supporter_count.entry(new_campaign_id).write(0);
            self.campaign_created_at.entry(new_campaign_id).write(current_timestamp);
            self.campaign_updated_at.entry(new_campaign_id).write(current_timestamp);
            self.campaign_paused_at.entry(new_campaign_id).write(0);
            self.campaign_completed_at.entry(new_campaign_id).write(0);

            // Update campaign counter
            self.campaign_counter.write(new_campaign_id);

            // Emit event
            self
                .emit(
                    Event::Created(
                        CampaignCreated {
                            campaign_id: new_campaign_id,
                            creator: creator,
                            status: CampaignStatus::Active,
                            supporter_count: 0,
                        },
                    ),
                );

            new_campaign_id
        }

        fn update_campaign_status(
            ref self: ContractState, campaign_id: u64, new_status: CampaignStatus,
        ) {
            self.assert_is_creator(campaign_id);
            let status = self.campaign_status.entry(campaign_id).read();
            assert(
                status == CampaignStatus::Active || status == CampaignStatus::Paused,
                'Invalid status',
            );

            self.campaign_status.entry(campaign_id).write(new_status);
            self.campaign_updated_at.entry(campaign_id).write(get_block_timestamp());

            self
                .emit(
                    Event::StatusUpdated(
                        CampaignStatusUpdated {
                            campaign_id: campaign_id,
                            status: new_status,
                            supporter_count: self
                                .campaign_supporter_count
                                .entry(campaign_id)
                                .read(),
                        },
                    ),
                );
        }

        fn pause_campaign(ref self: ContractState, campaign_id: u64) {
            self.assert_is_admin();

            self.campaign_status.entry(campaign_id).write(CampaignStatus::Paused);
            self.campaign_updated_at.entry(campaign_id).write(get_block_timestamp());
            self.campaign_paused_at.entry(campaign_id).write(get_block_timestamp());
            self.emit(Event::HoldCampaign(CampaignPaused { campaign_id }));
        }

        fn unpause_campaign(ref self: ContractState, campaign_id: u64) {
            self.assert_is_admin();

            self.campaign_status.entry(campaign_id).write(CampaignStatus::Active);
            self.campaign_updated_at.entry(campaign_id).write(get_block_timestamp());
            self.campaign_paused_at.entry(campaign_id).write(0);

            self.emit(Event::UnholdCampaign(CampaignUnpaused { campaign_id: campaign_id }));
        }

        fn get_campaign_stats(self: @ContractState, campaign_id: u64) -> CamapaignStats {
            self.assert_is_creator(campaign_id);
            let campaign = self.campaigns.entry(campaign_id).read();

            CamapaignStats {
                campaign_id: campaign_id,
                status: self.campaign_status.entry(campaign_id).read(),
                supporter_count: self.campaign_supporter_count.entry(campaign_id).read(),
                creator: campaign.creator,
                created_at: self.campaign_created_at.entry(campaign_id).read(),
                updated_at: self.campaign_updated_at.entry(campaign_id).read(),
                paused_at: self.campaign_paused_at.entry(campaign_id).read(),
                completed_at: self.campaign_completed_at.entry(campaign_id).read(),
            }
        }

        fn admin_get_campaign_stats(self: @ContractState, campaign_id: u64) -> CamapaignStats {
            self.assert_is_admin();
            let campaign = self.campaigns.entry(campaign_id).read();

            CamapaignStats {
                campaign_id: campaign_id,
                status: self.campaign_status.entry(campaign_id).read(),
                supporter_count: self.campaign_supporter_count.entry(campaign_id).read(),
                creator: campaign.creator,
                created_at: self.campaign_created_at.entry(campaign_id).read(),
                updated_at: self.campaign_updated_at.entry(campaign_id).read(),
                paused_at: self.campaign_paused_at.entry(campaign_id).read(),
                completed_at: self.campaign_completed_at.entry(campaign_id).read(),
            }
        }

        fn get_top_campaigns(self: @ContractState) -> Array<u64> {
            let mut top_campaigns = ArrayTrait::new();
            let mut max_supporters = 0_u64;
            let mut i = 1;
            let campaign_count = self.campaign_counter.read();

            // Find the max supporter count
            while i != campaign_count + 1 {
                let supporters = self.campaign_supporter_count.entry(i).read();
                if supporters > max_supporters {
                    max_supporters = supporters;
                }
                i += 1;
            }

            // Collect all campaigns with max supporter count
            i = 1;
            while i != campaign_count + 1 {
                if self.campaign_supporter_count.entry(i).read() == max_supporters {
                    top_campaigns.append(i);
                }
                i += 1;
            }

            top_campaigns
        }

        fn approve_creator(ref self: ContractState, creator: ContractAddress) {
            self.assert_is_admin();
            self.approved_creators.entry(creator).write(true);
        }

        fn get_last_campaign_id(self: @ContractState) -> u64 {
            self.campaign_counter.read()
        }

        fn add_supporter(ref self: ContractState, campaign_id: u64, supporter: ContractAddress) {
            self.assert_is_creator(campaign_id);
            let current_count = self.campaign_supporter_count.entry(campaign_id).read();
            self.campaign_supporter_count.entry(campaign_id).write(current_count + 1);
            self.campaign_supporters.entry((campaign_id, supporter)).write(true);
        }

        fn update_campaign_metadata(ref self: ContractState, campaign_id: u64, metadata: felt252) {
            // This function is kept for interface compatibility but does nothing
            // since we no longer store metadata as a single felt252 field
            self.assert_is_creator(campaign_id);
            // Metadata is now stored as title, description, etc. in the Campaign struct
        }


        fn get_campaigns(self: @ContractState) -> Array<u64> {
            let mut campaigns = ArrayTrait::new();
            let campaign_count = self.campaign_counter.read();

            let mut i = 1;
            while i != campaign_count + 1 {
                let campaign = self.campaigns.entry(i).read();
                campaigns.append(campaign.id);
                i += 1;
            }

            campaigns
        }

        fn get_featured_campaigns(self: @ContractState) -> Array<u64> {
            let mut featured_campaigns = ArrayTrait::new();
            let mut max_supporters = 0_u64;
            let mut i = 1;
            let campaign_count = self.campaign_counter.read();

            while i != campaign_count + 1 {
                let status = self.campaign_status.entry(i).read();
                if status == CampaignStatus::Active {
                    let supporters = self.campaign_supporter_count.entry(i).read();
                    if supporters > max_supporters {
                        max_supporters = supporters;
                    }
                }
                i += 1;
            }

            i = 1;
            while i != campaign_count + 1 {
                let status = self.campaign_status.entry(i).read();
                if status == CampaignStatus::Active
                    && self.campaign_supporter_count.entry(i).read() == max_supporters {
                    featured_campaigns.append(i);
                }
                i += 1;
            }

            featured_campaigns
        }

        fn get_user_campaigns(self: @ContractState, user: ContractAddress) -> Array<u64> {
            let mut user_campaigns = ArrayTrait::new();
            let campaign_count = self.campaign_counter.read();

            let mut i = 1;
            while i != campaign_count + 1 {
                let campaign = self.campaigns.entry(i).read();
                if campaign.creator == user {
                    user_campaigns.append(campaign.id);
                }
                i += 1;
            }

            user_campaigns
        }
        fn contribute(
            ref self: ContractState, campaign_id: u64, amount: u256, token_address: ContractAddress,
        ) {
            // Check if contract is paused
            self.pausable.assert_not_paused();

            // Validate inputs
            assert(campaign_id > 0, 'Invalid campaign ID');
            assert(amount > 0, 'Amount must be greater than 0');
            assert(!token_address.is_zero(), 'Invalid token address');

            let contributor = get_caller_address();
            assert(!contributor.is_zero(), 'Invalid contributor address');

            // Check if campaign exists and is active
            let campaign = self.campaigns.entry(campaign_id).read();
            assert(campaign.id == campaign_id, 'Campaign does not exist');
            assert(campaign.is_active, 'Campaign is not active');

            let campaign_status = self.campaign_status.entry(campaign_id).read();
            assert(campaign_status == CampaignStatus::Active, 'Campaign is not active');

            // Transfer tokens from contributor to contract
            let token = IERC20Dispatcher { contract_address: token_address };
            let success = token.transfer_from(contributor, get_contract_address(), amount);
            assert(success, 'Token transfer failed');

            // Update contribution storage
            let current_contribution = self.contributions.entry((campaign_id, contributor)).read();
            let new_contribution = current_contribution + amount;
            self.contributions.entry((campaign_id, contributor)).write(new_contribution);

            // Update campaign total contributions
            let current_campaign_total = self
                .campaign_total_contributions
                .entry(campaign_id)
                .read();
            let new_campaign_total = current_campaign_total + amount;
            self.campaign_total_contributions.entry(campaign_id).write(new_campaign_total);

            // Update user total contributions
            let current_user_total = self.user_total_contributions.entry(contributor).read();
            let new_user_total = current_user_total + amount;
            self.user_total_contributions.entry(contributor).write(new_user_total);

            // Update campaign amount_raised
            let mut updated_campaign = campaign;
            updated_campaign.amount_raised = updated_campaign.amount_raised + amount;
            updated_campaign
                .contributors_count =
                    if current_contribution == 0 {
                        updated_campaign.contributors_count + 1
                    } else {
                        updated_campaign.contributors_count
                    };
            self.campaigns.entry(campaign_id).write(updated_campaign);

            // Add supporter if first time contributing
            if current_contribution == 0 {
                self.campaign_supporters.entry((campaign_id, contributor)).write(true);
                let current_supporter_count = self
                    .campaign_supporter_count
                    .entry(campaign_id)
                    .read();
                self.campaign_supporter_count.entry(campaign_id).write(current_supporter_count + 1);
            }

            // Update campaign timestamp
            let current_timestamp = get_block_timestamp();
            self.campaign_updated_at.entry(campaign_id).write(current_timestamp);

            // Emit contribution event
            self
                .emit(
                    Event::ContributionProcessed(
                        ContributionProcessed {
                            campaign_id: campaign_id, contributor: contributor, amount: amount,
                        },
                    ),
                );
        }

        fn get_contribution(
            self: @ContractState, campaign_id: u64, contributor: ContractAddress,
        ) -> u256 {
            self.contributions.entry((campaign_id, contributor)).read()
        }

        fn get_campaign_contributions(self: @ContractState, campaign_id: u64) -> u256 {
            self.campaign_total_contributions.entry(campaign_id).read()
        }

        /// @notice Checks if the given address is an admin or owner of the contract
        /// @param address The address to check
        /// @return bool True if the address is an admin or owner, false otherwise
        fn is_admin_or_owner(self: @ContractState, address: ContractAddress) -> bool {
            // Check if address is the contract owner
            let owner = self.owner.read();
            if address == owner {
                return true;
            }

            // Check if address is in the admins mapping
            if self.admins.entry(address).read() {
                return true;
            }

            // Check if address has DEFAULT_ADMIN_ROLE (OpenZeppelin AccessControl)
            let has_admin_role = self.accesscontrol.has_role(DEFAULT_ADMIN_ROLE, address);
            if has_admin_role {
                return true;
            }

            // Check if address has PAUSER_ROLE or UPGRADER_ROLE (admin-level roles)
            let has_pauser_role = self.accesscontrol.has_role(PAUSER_ROLE, address);
            let has_upgrader_role = self.accesscontrol.has_role(UPGRADER_ROLE, address);
            let has_admin_role = self.accesscontrol.has_role(ADMIN_ROLE, address);

            has_pauser_role || has_upgrader_role || has_admin_role
        }

        /// @notice Checks if the given address is an approved creator
        /// @param address The wallet address to verify
        /// @return bool True if the address is an approved creator, false otherwise
        fn is_approved_creator(self: @ContractState, address: ContractAddress) -> bool {
            self.approved_creators.entry(address).read()
        }

        /// @notice Returns the contract owner address
        /// @return ContractAddress The owner's address
        fn get_owner(self: @ContractState) -> ContractAddress {
            self.owner.read()
        }

        /// @notice Adds a new admin to the contract (only owner can call)
        /// @param admin The address to add as admin
        fn add_admin(ref self: ContractState, admin: ContractAddress) {
            // Only owner can add admins
            let caller = get_caller_address();
            let owner = self.owner.read();
            assert(caller == owner, 'Only owner can add admins');

            // Check if already an admin
            if self.admins.entry(admin).read() {
                return; // Already an admin, do nothing
            }

            // Add to admins mapping
            self.admins.entry(admin).write(true);

            // Add to admin_addresses array
            let current_count = self.admin_count.read();
            self.admin_addresses.entry(current_count).write(admin);
            self.admin_count.write(current_count + 1);
        }

        /// @notice Removes an admin from the contract (only owner can call)
        /// @param admin The address to remove as admin
        fn remove_admin(ref self: ContractState, admin: ContractAddress) {
            // Only owner can remove admins
            let caller = get_caller_address();
            let owner = self.owner.read();
            assert(caller == owner, 'Only owner can remove admins');

            // Cannot remove owner
            assert(admin != owner, 'Cannot remove owner');

            // Check if actually an admin
            if !self.admins.entry(admin).read() {
                return; // Not an admin, do nothing
            }

            // Remove from admins mapping
            self.admins.entry(admin).write(false);
            // Note: We don't remove from admin_addresses array to maintain indices
        // The is_admin function will check the admins mapping for active status
        }

        /// @notice Checks if an address is an admin (not including owner)
        /// @param address The address to check
        /// @return bool True if the address is an admin, false otherwise
        fn is_admin(self: @ContractState, address: ContractAddress) -> bool {
            self.admins.entry(address).read()
        }

        /// @notice Returns the total number of admins (including inactive ones)
        /// @return u32 The total admin count
        fn get_admin_count(self: @ContractState) -> u32 {
            self.admin_count.read()
        }

        /// @notice Returns the admin address at a specific index
        /// @param index The index to query
        /// @return ContractAddress The admin address at the given index
        fn get_admin_by_index(self: @ContractState, index: u32) -> ContractAddress {
            assert(index < self.admin_count.read(), 'Index out of bounds');
            self.admin_addresses.entry(index).read()
        }

        /// @notice Returns all admin addresses (including inactive ones)
        /// @return Array<ContractAddress> Array of all admin addresses
        fn get_all_admins(self: @ContractState) -> Array<ContractAddress> {
            let mut admins = ArrayTrait::new();
            let admin_count = self.admin_count.read();
            let mut i = admin_count;

            while i != 0 {
                i -= 1;
                let admin_address = self.admin_addresses.entry(i).read();
                admins.append(admin_address);
            }

            admins
        }
    }

    #[generate_trait]
    impl Private of PrivateTrait {
        fn assert_is_admin(self: @ContractState) {
            let caller = get_caller_address();
            assert(self.is_admin_or_owner(caller), 'Caller is not admin');
        }

        fn assert_is_creator(self: @ContractState, campaign_id: u64) {
            let campaign = self.campaigns.entry(campaign_id).read();
            let creator = campaign.creator;
            let caller = get_caller_address();
            assert(creator == caller, 'Caller is not the creator');
        }
    }
}

