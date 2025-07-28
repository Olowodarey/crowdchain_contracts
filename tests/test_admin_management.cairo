use crowdchain_contracts::interfaces::ICrowdchain::{
    ICrowdchainDispatcher, ICrowdchainDispatcherTrait,
};
use snforge_std::{
    ContractClassTrait, DeclareResultTrait, declare, start_cheat_caller_address,
    stop_cheat_caller_address,
};
use starknet::ContractAddress;

// ********** ADDRESS FUNCTIONS **********

fn owner_address() -> ContractAddress {
    let owner_felt: felt252 = 0001.into();
    let owner: ContractAddress = owner_felt.try_into().unwrap();
    owner
}

fn admin1_address() -> ContractAddress {
    let admin1_felt: felt252 = 0002.into();
    let admin1: ContractAddress = admin1_felt.try_into().unwrap();
    admin1
}

fn admin2_address() -> ContractAddress {
    let admin2_felt: felt252 = 0003.into();
    let admin2: ContractAddress = admin2_felt.try_into().unwrap();
    admin2
}

fn admin3_address() -> ContractAddress {
    let admin3_felt: felt252 = 0004.into();
    let admin3: ContractAddress = admin3_felt.try_into().unwrap();
    admin3
}

fn non_admin_address() -> ContractAddress {
    let non_admin_felt: felt252 = 0005.into();
    let non_admin: ContractAddress = non_admin_felt.try_into().unwrap();
    non_admin
}

fn creator_address() -> ContractAddress {
    let creator_felt: felt252 = 0006.into();
    let creator: ContractAddress = creator_felt.try_into().unwrap();
    creator
}

// ********** SETUP FUNCTION **********

fn setup() -> (ICrowdchainDispatcher, ContractAddress, ContractAddress) {
    let contract = declare("Crowdchain").unwrap().contract_class();
    let owner = owner_address();
    let calldata = array![owner.into()];
    let (contract_address, _) = contract.deploy(@calldata).unwrap();
    let campaign_dispatcher = ICrowdchainDispatcher { contract_address };
    (campaign_dispatcher, contract_address, owner)
}

// ********** ADMIN MANAGEMENT TESTS **********

#[test]
fn test_initial_state() {
    let (campaign_dispatcher, _, owner) = setup();

    // Owner should be the owner
    assert(campaign_dispatcher.get_owner() == owner, 'Owner should be set correctly');

    // Admin count should be 0 (owner is not counted as admin)
    assert(campaign_dispatcher.get_admin_count() == 0, 'Admin count should be 0');

    // Owner should be admin_or_owner but not admin
    assert(campaign_dispatcher.is_admin_or_owner(owner), 'Owner should be admin_or_owner');
    assert(!campaign_dispatcher.is_admin(owner), 'Owner should not be admin');

    // All admins array should be empty
    let all_admins = campaign_dispatcher.get_all_admins();
    assert(all_admins.len() == 0, 'All admins should be empty');
}

#[test]
fn test_owner_can_add_admin() {
    let (campaign_dispatcher, contract_address, owner) = setup();
    let admin1 = admin1_address();

    start_cheat_caller_address(contract_address, owner);

    // Add admin
    campaign_dispatcher.add_admin(admin1);

    // Verify admin was added
    assert(campaign_dispatcher.is_admin(admin1), 'Admin1 should be admin');
    assert(campaign_dispatcher.is_admin_or_owner(admin1), 'Admin1 should be admin_or_owner');
    assert(campaign_dispatcher.get_admin_count() == 1, 'Admin count should be 1');

    // Verify admin is in all_admins array
    let all_admins = campaign_dispatcher.get_all_admins();
    assert(all_admins.len() == 1, 'All admins should have 1 admin');
    assert(*all_admins.at(0) == admin1, 'First admin should be admin1');

    stop_cheat_caller_address(contract_address);
}

#[test]
fn test_owner_can_add_multiple_admins() {
    let (campaign_dispatcher, contract_address, owner) = setup();
    let admin1 = admin1_address();
    let admin2 = admin2_address();
    let admin3 = admin3_address();

    start_cheat_caller_address(contract_address, owner);

    // Add multiple admins
    campaign_dispatcher.add_admin(admin1);
    campaign_dispatcher.add_admin(admin2);
    campaign_dispatcher.add_admin(admin3);

    // Verify all admins were added
    assert(campaign_dispatcher.is_admin(admin1), 'Admin1 should be admin');
    assert(campaign_dispatcher.is_admin(admin2), 'Admin2 should be admin');
    assert(campaign_dispatcher.is_admin(admin3), 'Admin3 should be admin');
    assert(campaign_dispatcher.get_admin_count() == 3, 'Admin count should be 3');

    // Verify all admins are in array (reverse order due to our optimization)
    let all_admins = campaign_dispatcher.get_all_admins();
    assert(all_admins.len() == 3, 'All admins should have 3 admins');
    assert(*all_admins.at(0) == admin3, 'First should be admin3');
    assert(*all_admins.at(1) == admin2, 'Second should be admin2');
    assert(*all_admins.at(2) == admin1, 'Third should be admin1');

    stop_cheat_caller_address(contract_address);
}

#[test]
fn test_add_duplicate_admin() {
    let (campaign_dispatcher, contract_address, owner) = setup();
    let admin1 = admin1_address();

    start_cheat_caller_address(contract_address, owner);

    // Add admin twice
    campaign_dispatcher.add_admin(admin1);
    campaign_dispatcher.add_admin(admin1); // Should do nothing

    // Verify admin count is still 1
    assert(campaign_dispatcher.get_admin_count() == 1, 'Admin count should be 1');
    assert(campaign_dispatcher.is_admin(admin1), 'Admin1 should be admin');

    let all_admins = campaign_dispatcher.get_all_admins();
    assert(all_admins.len() == 1, 'All admins should have 1 admin');

    stop_cheat_caller_address(contract_address);
}

#[test]
#[should_panic(expected: 'Only owner can add admins')]
fn test_non_owner_cannot_add_admin() {
    let (campaign_dispatcher, contract_address, _) = setup();
    let admin1 = admin1_address();
    let non_admin = non_admin_address();

    start_cheat_caller_address(contract_address, non_admin);
    campaign_dispatcher.add_admin(admin1);
}

#[test]
#[should_panic(expected: 'Only owner can add admins')]
fn test_admin_cannot_add_other_admin() {
    let (campaign_dispatcher, contract_address, owner) = setup();
    let admin1 = admin1_address();
    let admin2 = admin2_address();

    // Owner adds admin1
    start_cheat_caller_address(contract_address, owner);
    campaign_dispatcher.add_admin(admin1);
    stop_cheat_caller_address(contract_address);

    // Admin1 tries to add admin2 (should fail)
    start_cheat_caller_address(contract_address, admin1);
    campaign_dispatcher.add_admin(admin2);
}

#[test]
fn test_owner_can_remove_admin() {
    let (campaign_dispatcher, contract_address, owner) = setup();
    let admin1 = admin1_address();

    start_cheat_caller_address(contract_address, owner);

    // Add admin then remove
    campaign_dispatcher.add_admin(admin1);
    assert(campaign_dispatcher.is_admin(admin1), 'Admin1 should be admin');

    campaign_dispatcher.remove_admin(admin1);
    assert(!campaign_dispatcher.is_admin(admin1), 'Admin1 should not be admin');
    assert(!campaign_dispatcher.is_admin_or_owner(admin1), 'Admin1 not admin_or_owner');

    // Admin count should still be 1 (historical tracking)
    assert(campaign_dispatcher.get_admin_count() == 1, 'Admin count should be 1');

    stop_cheat_caller_address(contract_address);
}

#[test]
fn test_remove_non_existent_admin() {
    let (campaign_dispatcher, contract_address, owner) = setup();
    let admin1 = admin1_address();

    start_cheat_caller_address(contract_address, owner);

    // Try to remove admin that was never added (should do nothing)
    campaign_dispatcher.remove_admin(admin1);
    assert(!campaign_dispatcher.is_admin(admin1), 'Admin1 should not be admin');
    assert(campaign_dispatcher.get_admin_count() == 0, 'Admin count should be 0');

    stop_cheat_caller_address(contract_address);
}

#[test]
#[should_panic(expected: 'Cannot remove owner')]
fn test_cannot_remove_owner() {
    let (campaign_dispatcher, contract_address, owner) = setup();

    start_cheat_caller_address(contract_address, owner);
    campaign_dispatcher.remove_admin(owner);
}

#[test]
#[should_panic(expected: 'Only owner can remove admins')]
fn test_non_owner_cannot_remove_admin() {
    let (campaign_dispatcher, contract_address, owner) = setup();
    let admin1 = admin1_address();
    let non_admin = non_admin_address();

    // Owner adds admin
    start_cheat_caller_address(contract_address, owner);
    campaign_dispatcher.add_admin(admin1);
    stop_cheat_caller_address(contract_address);

    // Non-admin tries to remove admin
    start_cheat_caller_address(contract_address, non_admin);
    campaign_dispatcher.remove_admin(admin1);
}

#[test]
#[should_panic(expected: 'Only owner can remove admins')]
fn test_admin_cannot_remove_other_admin() {
    let (campaign_dispatcher, contract_address, owner) = setup();
    let admin1 = admin1_address();
    let admin2 = admin2_address();

    // Owner adds both admins
    start_cheat_caller_address(contract_address, owner);
    campaign_dispatcher.add_admin(admin1);
    campaign_dispatcher.add_admin(admin2);
    stop_cheat_caller_address(contract_address);

    // Admin1 tries to remove admin2 (should fail)
    start_cheat_caller_address(contract_address, admin1);
    campaign_dispatcher.remove_admin(admin2);
}

// ********** CREATOR APPROVAL TESTS **********

#[test]
fn test_owner_can_approve_creator() {
    let (campaign_dispatcher, contract_address, owner) = setup();
    let creator = creator_address();

    start_cheat_caller_address(contract_address, owner);

    // Initially not approved
    assert(!campaign_dispatcher.is_approved_creator(creator), 'Creator should not be approved');

    // Approve creator
    campaign_dispatcher.approve_creator(creator);
    assert(campaign_dispatcher.is_approved_creator(creator), 'Creator should be approved');

    stop_cheat_caller_address(contract_address);
}

#[test]
fn test_admin_can_approve_creator() {
    let (campaign_dispatcher, contract_address, owner) = setup();
    let admin1 = admin1_address();
    let creator = creator_address();

    // Owner adds admin
    start_cheat_caller_address(contract_address, owner);
    campaign_dispatcher.add_admin(admin1);
    stop_cheat_caller_address(contract_address);

    // Admin approves creator
    start_cheat_caller_address(contract_address, admin1);
    campaign_dispatcher.approve_creator(creator);
    assert(campaign_dispatcher.is_approved_creator(creator), 'Creator should be approved');

    stop_cheat_caller_address(contract_address);
}

#[test]
fn test_role_verification_functions() {
    let (campaign_dispatcher, contract_address, owner) = setup();
    let admin1 = admin1_address();
    let creator = creator_address();
    let non_admin = non_admin_address();

    start_cheat_caller_address(contract_address, owner);
    campaign_dispatcher.add_admin(admin1);
    campaign_dispatcher.approve_creator(creator);
    stop_cheat_caller_address(contract_address);

    // Test owner
    assert(campaign_dispatcher.get_owner() == owner, 'Owner should be correct');
    assert(campaign_dispatcher.is_admin_or_owner(owner), 'Owner should be admin_or_owner');
    assert(!campaign_dispatcher.is_admin(owner), 'Owner should not be admin');
    assert(!campaign_dispatcher.is_approved_creator(owner), 'Owner should not be creator');

    // Test admin
    assert(campaign_dispatcher.is_admin_or_owner(admin1), 'Admin should be admin_or_owner');
    assert(campaign_dispatcher.is_admin(admin1), 'Admin should be admin');
    assert(!campaign_dispatcher.is_approved_creator(admin1), 'Admin should not be creator');

    // Test creator
    assert(!campaign_dispatcher.is_admin_or_owner(creator), 'Creator not admin_or_owner');
    assert(!campaign_dispatcher.is_admin(creator), 'Creator should not be admin');
    assert(campaign_dispatcher.is_approved_creator(creator), 'Creator should be approved');

    // Test non-admin
    assert(!campaign_dispatcher.is_admin_or_owner(non_admin), 'Non-admin not admin_or_owner');
    assert(!campaign_dispatcher.is_admin(non_admin), 'Non-admin should not be admin');
    assert(!campaign_dispatcher.is_approved_creator(non_admin), 'Non-admin should not be creator');
}

#[test]
fn test_get_admin_by_index() {
    let (campaign_dispatcher, contract_address, owner) = setup();
    let admin1 = admin1_address();
    let admin2 = admin2_address();

    start_cheat_caller_address(contract_address, owner);

    // Add admins
    campaign_dispatcher.add_admin(admin1);
    campaign_dispatcher.add_admin(admin2);

    // Test get_admin_by_index
    assert(campaign_dispatcher.get_admin_by_index(0) == admin1, 'Index 0 should be admin1');
    assert(campaign_dispatcher.get_admin_by_index(1) == admin2, 'Index 1 should be admin2');

    stop_cheat_caller_address(contract_address);
}

#[test]
#[should_panic(expected: 'Index out of bounds')]
fn test_get_admin_by_index_out_of_bounds() {
    let (campaign_dispatcher, contract_address, owner) = setup();
    let admin1 = admin1_address();

    start_cheat_caller_address(contract_address, owner);
    campaign_dispatcher.add_admin(admin1);

    // Try to access index 1 when only index 0 exists
    campaign_dispatcher.get_admin_by_index(1);
}
