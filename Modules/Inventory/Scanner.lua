-- Modules/Inventory/Scanner.lua
-- Which owned stock counts: for the route, every total and the shopping list.
--
-- The bags are always read live (through the client adapter). Stock outside
-- them comes from one of two places:
--   - the Syndicator addon, when it is installed: bank, mail, own auctions,
--     alts, guild bank. LazyProf's own memory is then neither read nor
--     written.
--   - otherwise LazyProf's own memory (StockMemory.lua): the character's bank
--     and the account bank as last read with the bank window open, and the
--     bags and banks of the other characters of the same world and faction.
--     The account bank is remembered once per region and counts only for
--     the characters of the world and faction whose read it is: whether the
--     game shares it across worlds or factions is not known, and a copy read
--     elsewhere may be another bank. This file keeps that memory up to date.
-- A Self-Found character cannot be sent anything, so nothing that belongs to
-- other characters is counted for it, from either place (alts, the account
-- bank, the guild bank); and it cannot send anything, so the memory does not
-- offer what it holds to the others. A character is Self-Found here when the
-- game itself marks it so (the client adapter asks) or the addon's Self-Found
-- setting is on; which recipes the planner allows follows the setting alone.
--
-- The memory can never stop the addon: everything that touches it runs
-- protected (see Protected), and a scan that cannot read it counts the bags.
-- The first failure of a session is handed to the game's error handler.
--
-- THE BAGS are remembered BAG_SAVE_DELAY (2 s) after a bag update - one save
-- for a burst of updates - and, when a save is still waiting, at logout. Bags
-- that report no backpack slots could not be read and are not saved. Bags
-- that read as completely empty are saved only when a bag update came before
-- the read: at login and at logout nothing says the client has the bags'
-- contents, and slots without items would otherwise replace the snapshot
-- with nothing. A slot that reads as locked (a move of it on its way) is
-- left out of a save: until the answer it shows what it held before the
-- click, which may be on its way into a slot already reported, and the
-- other characters would be offered it twice.
--
-- THE BANK (the character's and the account's; WoW Forever only) is read only
-- while its window is open, and never by a scan: a scan counts what is
-- remembered. What is remembered of a bank is either what a read that can be
-- trusted saw, or it is marked IN DOUBT and not counted until the next
-- visit. It is never replaced by "nothing" on weak evidence, and it stops
-- being counted as soon as there is reason to think it changed without being
-- read.
-- That reason is always the bank's own: one of ITS containers reported a
-- change that no kept read has seen. A change of the carried bags is no
-- such sign by itself - they change for many reasons that have nothing to do
-- with a bank, and a move between the two banks changes none of them. Only
-- where the bank can no longer report (after the close on a client that
-- does not send its updates then, and after the session) the carried bags
-- are all there is to go by, and then only a count that rose, or bags that
-- are not what the last session left.
-- Not known about the client, and so not assumed either way: whether the bank
-- can still be read inside the close notice; whether the bag updates of a
-- last move can arrive after the window closed, and for which containers;
-- whether the client empties the bank's containers (keeping their slots) and
-- sends bag updates before or after the close notice; whether the two bag
-- updates of one move come in one frame; whether the items are all there the
-- moment the window opens; whether bank containers report while the window
-- is closed (at login, or for a craft that takes reagents from the bank);
-- how long the answer of a move can take. Taken from the client: a slot
-- reads as locked from the click of a move until its answer (an empty slot
-- has no item to show it).
--
-- 1. When the bank is read.
--    - At once when the window opens, and again BANK_SETTLE (0.5 s) and
--      BANK_EMPTY_TRUST (2 s) after the opening, whatever the reads before
--      gave: a bank that was there only in part at the opening and
--      completed without a bag update is then read whole while its window
--      is still open. (A look finds nothing to do when another read was
--      taken at or after its mark.)
--    - Again BANK_SETTLE after the last read, for as long as the window is
--      open and a bank usable in the visit is unsettled (rule 3), has an
--      empty read not believed yet, or was refused at its last read: no
--      event may come to say that it can be read again (a bank that is
--      locked for a moment, say). One timer at most.
--    - On a bag update (of any container: an item may have gone into the
--      bank or come out of it) or a change of the bank's tabs: at once when
--      the last read is BANK_READ_SPACING (0.2 s) or more ago. Otherwise the
--      read is owed, and one trailing read is taken 0.2 s after the last
--      read.
--    - When the client says that a batch of bag updates is complete
--      (BAG_UPDATE_DELAYED): an owed read is taken at once when the last
--      read was taken in this very frame (it came before the batch was
--      complete) or is 0.2 s old. On a later frame within the 0.2 s the
--      trailing read stays in charge, so a burst that runs over many frames
--      is not read in every one of them.
--    Reading both banks in full costs about a millisecond and leaves a table
--    per slot behind; the 0.2 s between reads is what bounds that.
-- 2. Which read is kept, bank by bank.
--    - Refused by the adapter: not kept.
--    - With items: kept.
--    - Without a single item while items are remembered: believed only when
--      (a) this visit already kept a read with items of the same slot count,
--      or it is 2 s or more after the opening, and (b) an earlier read of
--      this visit, taken on an earlier frame and after the bank's last own
--      update, found the bank empty too (an empty read from before an
--      update says nothing about the bank after it: a stack may have gone
--      in). Until then the empty read is unresolved and more reads are
--      taken: the trailing read when only (b) is missing, else the reads
--      every BANK_SETTLE and the look at 2 s.
--    - Without a single item while nothing with items is remembered for that
--      bank: kept 2 s or more after the opening ("seen, nothing in it") -
--      and, while the bank is unsettled (rule 3), only on a second look as
--      in (b): a deposit may just have gone in, and the client may be
--      letting go of the bank.
--    A kept read replaces what is remembered and takes a doubt mark away.
-- 3. Unsettled. A bank is UNSETTLED from the moment an update of one of its
--    own containers arrives, or its tabs change, until a read of that bank
--    taken after that update is kept. That is a matter of order, not of
--    frames: a read taken in the handler of the update itself comes after
--    it; a read taken earlier in the same frame does not. An update of a
--    carried bag unsettles no bank. An empty read that is not believed
--    (rule 2) is not kept, so it settles nothing; neither does a read the
--    adapter refused.
--    An opening notice that comes again while the bank is open (the banker
--    clicked again) begins no visit of its own: the visit keeps all it knows
--    (which bank was usable, which is unsettled, which was refused, what
--    its reads saw), both banks are unsettled from that notice on as by an
--    update of their own containers, and they are read again as on a bag
--    update (rule 1). The dump counts such notices (openedAgain).
--    While the window is open a scan leaves out, and says so in its third
--    return (bankPending, accountPending - no line is shown for that):
--    - a bank that is unsettled;
--    - both banks while a read is owed, that is, an update of any container
--      has arrived since the last read and the read waits for the 0.2 s
--      spacing;
--    - a bank whose last read found it empty without being believed (its
--      last stack may just have gone into the other bank, whose update came
--      first - the emptied bank's own update is still to come);
--    - a bank whose last read was refused (locked for a moment, say): a read
--      taken for a carried bag's update could not see it, and the bank's
--      own part of that move may still be to come.
--    The next read that is kept brings them back.
-- 4. The close: the adapter's closing notice, which comes while the bank
--    still counts as open, and likewise a logout with the bank open. When a
--    bank is unsettled or a read is owed, the bank is read once more, and a
--    bank is kept from that read only when the read is not refused, holds
--    at least one item and has the slot count of the last read kept in this
--    visit. Then a bank of the visit is marked in doubt
--    - when it is still unsettled - except when a read of it taken since
--      its last own update (before the closing notice) found it empty and
--      was not believed (rule 2), and it is remembered as empty or not at
--      all: what is remembered then agrees with what was read;
--    - when such an unbelieved empty read, taken since its last own update,
--      stands and items of it are remembered: that is a sign that it was
--      emptied, and the old contents must not count again after the close;
--    - when a move is still on its way: the client locks the slots of a
--      move from the click until its answer, and when a slot of the
--      carried bags or of a bank that can be read reads as locked (the
--      adapter's MoveInFlight; locks that cannot be read count as a lock),
--      the answer may come after the close - for the carried bag alone on
--      a client that does not report the bank's containers then. So does a
--      lock that a kept read of this visit saw in a bank (every read of the
--      bank reports its locked slots too) when no update of that bank's
--      own containers has come since and no later kept read of it showed
--      none: the bank may not be readable at the closing notice, and its
--      part of a withdrawal whose carried part was answered before the
--      close may never be reported. Either way every bank of the visit is
--      marked, and the dump says moveInFlight=true.
--    Nothing else marks at the close: not a read that was owed for an
--    update of a carried bag, not such an update itself.
--    A bank that is not unsettled and not marked, for which a read was
--    owed and the closing read was not kept, and of which items are
--    remembered, is HELD instead: for CLOSE_WATCH (1 s) after the close - up
--    to the moment the timer that ends that second runs - a scan leaves it
--    out, as being read. Its own update may be the one that
--    is still to come (a client can change both containers of a move with
--    the carried bag's update and report the bank's container later); when
--    it comes, rule 5a marks the bank. When none comes in that second the
--    bank counts again, unmarked. When the session ends inside that second
--    the bank is marked: its update could never be heard.
-- 5. After the close the bank cannot be read. What may still arrive is the
--    answer of a last move, and a craft may take reagents from the closed
--    bank.
--    (a) An update of a bank container while the bank is closed marks that
--        bank in doubt at once, in the handler of the update, whenever it
--        comes: the character's own bank, or the account bank of its region
--        (whoever's read that copy is). Only in the first LOGIN_QUIET (10 s)
--        of a session that has had no visit yet is it merely counted: the
--        client may be loading the bank's containers then. Every one is
--        counted for /lp diag stock. (On a client that empties the bank's
--        containers after the close and reports it, or sends updates that
--        change nothing, every visit ends in doubt by this rule; the dump
--        shows whether a client does.)
--    (b) The carried bags' contents (item -> count) are noted at the closing
--        notice. When, within CLOSE_WATCH (1 s) after the close, the carried
--        count of an item has RISEN against that note and a remembered bank
--        of the visit holds that item, that bank is marked in doubt - also
--        when it was loot or a craft: the two cannot be told apart. For a
--        bank whose locks could not be seen at the closing notice (it could
--        not be read then, or read as empty while items of it are
--        remembered) the watch is CLOSE_WATCH_BLIND (3 s): a move from it
--        into an empty carried slot shows no lock, and its answer may come
--        late. A count that fell, or rose for an item no remembered bank of
--        the visit holds, marks nothing. The comparison is made on the next frame
--        after an update of a carried bag, when the bank is opened again,
--        and at logout; bags that cannot be read then are not compared,
--        and the comparison stays due. Each comparison lowers the note to
--        the counts that have fallen (what is used up after the close must
--        not hide a stack that arrives after it). A scan that comes before
--        the comparison neither marks nor touches the note: it leaves a
--        bank out of its own count (as being read) when the count it has
--        just read has risen for an item that bank holds - risen against
--        the note or against what an earlier scan of the same frame saw.
--        Within one frame a stack on its way from one carried bag to
--        another can show in both, or in neither; by the next frame the
--        count is what it was.
--        A comparison that is due while the bags cannot be read is tried on
--        every later frame until they can; when the watch is over (or the
--        session ends) with it still due, the visit's banks of which items
--        are remembered are marked.
--        When no note could be taken at the close (the bags could not be
--        read), an update of a carried bag marks at once each bank of the
--        visit whose watch it comes in (the second, or the three seconds of
--        a bank whose locks could not be seen).
--    (c) The end of the session. An answer that arrives after the session
--        has ended (a logout or a reload) cannot be seen by that session;
--        the next one can tell, because nothing else changes the carried
--        bags in between. So when a session ends with the bank open, or
--        within CLOSE_WATCH_BANK (10 s) after a close, what the carried
--        bags hold is saved with the character's record as "the bags at the
--        bank": read at that moment when they can be read and hold
--        something (completely empty bags are not trusted at logout),
--        otherwise the note of the close; when there is neither, the fact
--        that it is not known. The note names the banks the visit could use.
--        The next session of that character compares its bags with the
--        note: on the frame after its first update of a carried bag (bags
--        without backpack slots wait for the next one); at the first save
--        of the bags two seconds after the start - by then bags that cannot
--        be read, or that read as completely empty without a bag update
--        having come (unless the note says they were empty too), are no
--        read to compare with, and while the character's id cannot be read
--        that save, and the comparison with it, is tried again every two
--        seconds; when the bank is opened; and at a logout that comes
--        before all of those (with bags that hold something; else the note
--        stays for the session after). Until then a scan leaves the banks
--        the note names out (bankPending, accountPending). A carried count
--        that has risen against the note for an item a noted bank is
--        remembered to hold marks that bank in doubt; a note that is not
--        known, a note whose time is damaged (not a number greater than
--        zero and not later than a day after now: StockMemory.SoundTime)
--        and bags that cannot be compared mark every bank it names. A
--        count that fell, or rose for an item no noted bank holds, marks
--        nothing: the answer of a deposit is seen on its way at the close
--        or the logout (its carried slot is locked), so such a difference
--        is the new session's own. Nor is the account bank marked when its
--        record was saved after the note was written (read by another
--        character since) and both times are sound: that read is newer than
--        anything the note is about. The character's own bank has no such
--        exception: nothing but damage can make it look saved after its own
--        last session's note. In every case the note is removed.
--    (d) A session that ends without its saved data written (the client is
--        killed or crashes) leaves nothing: the next one starts from what
--        the session before it saved, and a withdrawal made in the lost
--        session is in the bags and still in the remembered bank. So a
--        session whose last one left no note compares its bags in the same
--        way - at the same moments, with the same safeguards, and leaving
--        the banks out until then - with the character's own bags as its
--        last save of them left them (taken at the start, before this
--        session's first save replaces them). A carried count that has
--        risen against that record for an item that the character's own
--        remembered bank, or the account bank as it counts for this
--        character (of its world and faction; not for a Self-Found
--        character; and only when this character has read it before - one
--        that may not view it cannot have changed it, and could not clear
--        the mark), holds marks that bank in doubt; bags that cannot be
--        compared, and a record whose time is damaged, mark each of those
--        banks that holds something. A count that fell, no record or a
--        record that cannot be read: no mark. There is no exception for a
--        bank saved after the record: after a lost session nothing tells
--        when its changes were made. The record stays (the next save
--        replaces it).
--    Which banks a visit can mark (rules 4, 5b and 5c), or leave out by
--    rule 3: only a bank that was USABLE at some moment of the visit - the
--    adapter says so (window open, the bank may be viewed, is not locked,
--    has a tab), and it is asked at every read of the visit, the closing
--    one included. A bank that never was (one this character may not view,
--    say) cannot have been changed through the visit: it is neither left
--    out nor marked, whatever is moved in the other one, and the note of
--    rule 5c does not name it. Rule 5a is the bank's own sign and marks the
--    bank whose container reported. A mark is only ever set on a bank of
--    which something is remembered.
-- 6. In doubt is a mark saved with the remembered bank (StockMemory.lua). A
--    bank that carries it is not counted by any scan - not for its own
--    character, not as an alt's bank (the alt's bags still count), not as
--    the account bank - and the scan's third return says so: bankInDoubt,
--    accountInDoubt, and altBanksInDoubt with the names of the alts whose
--    bank is left out. The Shopping tab shows a line for each. The next
--    kept read of that bank takes the mark away. A bank whose time read
--    back is damaged is left out and named the same way (the dump says
--    "time damaged"); an alt's bags with a damaged time are not counted.
--    Every mark, and every change of what a scan leaves out, drops the
--    frame's scan at once (a later scan of the same frame sees it) and asks
--    a shown list to redraw.
--
-- What these rules cannot see, or accept on purpose:
--    - A move that is answered after the session has ended, where its locks
--      could not be seen at the close or the logout (rule 4). The session
--      that ends never hears the answer. The character's next session
--      notices when a carried count rose against what the last one left
--      (rule 5c), but not every such move shows there: one between the
--      character bank and the account bank changes no carried bag; two
--      moves can cancel in the bags. And another character that plays
--      before the first one returns counts that character's bags and banks
--      as they were remembered when it left - the right sum until it reads
--      the account bank itself. Telling would mean distrusting an alt's
--      remembered bags after every logout at the bank, which would cost the
--      ordinary bank alt its stock.
--    - A logout while the answer of a move is on its way whose lock is seen
--      (rule 4 marks the banks of the visit): another character that plays
--      before this one returns counts its bags as they were last saved - a
--      move clicked after that save shows as not made yet, so a stack put
--      into a bank just before the logout is still counted in those bags.
--    - A mark another character set on a bank this one may not view. The
--      account bank's mark is the account's: a character that could use
--      that bank set it for a reason, and one that may not view the bank
--      sees it left out and cannot read it to take the mark away. Only a
--      character that can open that bank clears it.
--    - A tab bought in a visit of under two seconds. A change of its tabs
--      unsettles a bank, and a bank that reads empty is not believed empty
--      before the look two seconds after the opening (nor when its slot
--      count is no longer that of the read that saw its items). Such a
--      visit ends with that bank in doubt, unless what is remembered of it
--      is empty. So does a glance of under two seconds at a bank that reads
--      empty while items of it are remembered (emptied by a hand the memory
--      did not see, or shown late by the client).
--    - On a client that does not report the bank's part of a move once the
--      window is closed: a move on its way at the close none of whose locks
--      can be seen then, nor was seen by a kept read of the visit (rule 4) -
--      its carried bag's part answered before the close, and its bank's part
--      going into an empty slot (an empty slot shows no lock: such a deposit
--      is remembered short, never twice), or out of a slot of a bank that
--      cannot be read at the closing notice when no kept read came between
--      the click and the close; or one into an empty carried slot from such
--      a bank, answered after the watch of rule 5b. Nothing shows it on its
--      way, and its bank's update never comes.
--    - A craft that takes reagents from the closed bank in the first ten
--      seconds of a session that has not opened the bank: its bank
--      container's update is only counted (rule 5a), and the remembered bank
--      stays as it was until the next visit. The same for any change of the
--      bank in that time (a bank interaction kept across a reload, say).
--    - A loot or a craft that raises a carried count of an item a bank
--      holds in the watch after a close, or in the next session before its
--      bags are compared with the note or the record: it cannot be told
--      from the answer of a withdrawal, and marks that bank (rules 5b, 5c,
--      5d). So does a stack that was on its way between two carried bags
--      at a logout away from the bank (a save leaves locked slots out of
--      the record, so it shows as risen against it).
--    - A session that ended without its saved data written (rule 5d): what
--      it did that the carried bags do not show is not seen by the next
--      one - a deposit (the bank is remembered short of it), a move between
--      the two banks, a craft from the closed bank, a withdrawal whose
--      stack left the bags again before the end - nor what it did after it
--      had compared a note of the session before (the next session
--      compares that note again, and an account bank read by another
--      character after that note is not marked by it). The marks it set are
--      lost with it. And another character that plays before it returns
--      counts its bags and banks as the session before left them.
--
-- How these rules are tested: the whole suite (scripts/run_tests.sh) is the
-- acceptance test for them - scripts/test_scanner.lua (each rule on a
-- stand-in adapter), scripts/test_stockflow.lua (whole sessions on the real
-- adapter) and scripts/test_stockfuzz.lua (a seeded random walk against a
-- model of what is owned) together. The random walk alone does not notice
-- when one of these is taken out; only the other two guard them:
--    rule 1: the read when a batch of bag updates is complete;
--    rule 2: an empty read of a bank remembered as empty, while the bank is
--      unsettled, kept only on a second look;
--    rule 3: an opening notice that comes again unsettling both banks;
--    rule 4: the closing read taken for an unsettled bank, and kept only with
--      the visit's slot count; the held second, its end when its timer runs,
--      and the mark when the session ends inside it; a lock a kept read saw,
--      and its end with an update of the bank's own containers;
--    rule 5a: the quiet first ten seconds of a session;
--    rule 5b: the longer watch for a bank whose locks could not be seen;
--      without a note, the mark of a carried update within each bank's own
--      watch; the mark of a comparison given up; the note lowered to the
--      counts that fell;
--    rule 5c: the note itself, also within ten seconds after a close; the
--      comparison at the opening and at a logout; the exception for an
--      account bank read after the note, and none for the own bank; a note
--      with a damaged time;
--    rule 5d: only the account bank this character counts and has read;
--    rule 6 and the scan: every mark and every end of a leaving-out seen by
--      a later scan of the same frame; marks and leaving-outs after the close
--      only for a bank usable in the visit; a bank with a damaged time not
--      counted.
local ADDON_NAME, LazyProf = ...

LazyProf.Inventory = {}
local Inventory = LazyProf.Inventory

-- ============================================================================
-- Layer 1: Source Providers
-- Each returns {[itemId] = count}
-- ============================================================================

-- The bags the character carries, read by the client adapter (which bags
-- there are and how a slot is read differ per client). After the items the
-- adapter's other two returns follow: the soulbound part of them, and the
-- backpack's slot count (zero: the bags could not be read just now).
function Inventory:ScanBags()
    return LazyProf.Client:BagContents()
end

-- Scan bags from Syndicator character data (for alts)
function Inventory:ScanBagsSyndicator(charData)
    local items = {}
    if not charData or not charData.bags then return items end

    for _, bag in ipairs(charData.bags) do
        if bag then
            for _, slot in ipairs(bag) do
                if slot and slot.itemID then
                    items[slot.itemID] = (items[slot.itemID] or 0) + (slot.itemCount or 1)
                end
            end
        end
    end

    return items
end

-- Scan bank via Syndicator character data
function Inventory:ScanBank(charData)
    local items = {}
    if not charData then return items end

    -- Legacy bank bags
    if charData.bank then
        for _, bag in ipairs(charData.bank) do
            if bag then
                for _, slot in ipairs(bag) do
                    if slot and slot.itemID then
                        items[slot.itemID] = (items[slot.itemID] or 0) + (slot.itemCount or 1)
                    end
                end
            end
        end
    end

    -- Modern bank tabs
    if charData.bankTabs then
        for _, tab in ipairs(charData.bankTabs) do
            if tab and tab.slots then
                for _, slot in ipairs(tab.slots) do
                    if slot and slot.itemID then
                        items[slot.itemID] = (items[slot.itemID] or 0) + (slot.itemCount or 1)
                    end
                end
            end
        end
    end

    return items
end

-- Scan mail from Syndicator character data
function Inventory:ScanMail(charData)
    local items = {}
    if not charData or not charData.mail then return items end

    for _, mailItem in ipairs(charData.mail) do
        if mailItem and mailItem.itemID then
            items[mailItem.itemID] = (items[mailItem.itemID] or 0) + (mailItem.itemCount or 1)
        end
    end

    return items
end

-- Scan active auctions from Syndicator character data
function Inventory:ScanAuctions(charData)
    local items = {}
    if not charData or not charData.auctions then return items end

    for _, auction in ipairs(charData.auctions) do
        if auction and auction.itemID then
            items[auction.itemID] = (items[auction.itemID] or 0) + (auction.itemCount or 1)
        end
    end

    return items
end

-- Scan guild bank via Syndicator API
function Inventory:ScanGuildBank()
    local items = {}
    if not Syndicator or not Syndicator.API then return items end

    local guildName = Syndicator.API.GetCurrentGuild()
    if not guildName then return items end

    local guildData = Syndicator.API.GetByGuildFullName(guildName)
    if not guildData or not guildData.bank then return items end

    for _, tab in ipairs(guildData.bank) do
        if tab and tab.isViewable and tab.slots then
            for _, slot in ipairs(tab.slots) do
                if slot and slot.itemID then
                    items[slot.itemID] = (items[slot.itemID] or 0) + (slot.itemCount or 1)
                end
            end
        end
    end

    return items
end

-- ============================================================================
-- Layer 2: Aggregator
-- Orchestrates which sources to scan based on config, merges results
-- ============================================================================

-- Per-character sources scanned via Syndicator charData
local PER_CHAR_SOURCES = {
    { key = "bank",     configKey = "includeBankItems" },
    { key = "mail",     configKey = nil },  -- always on
    { key = "auctions", configKey = nil },  -- always on
}

-- Merge items from a source into combined inventory and sourceBreakdown
local function mergeSource(items, sourceKey, charName, combined, breakdown)
    for itemId, count in pairs(items) do
        combined[itemId] = (combined[itemId] or 0) + count

        if not breakdown[itemId] then
            breakdown[itemId] = {}
        end

        if charName then
            -- Alt character source
            if not breakdown[itemId].alts then
                breakdown[itemId].alts = {}
            end
            if not breakdown[itemId].alts[charName] then
                breakdown[itemId].alts[charName] = {}
            end
            breakdown[itemId].alts[charName][sourceKey] = (breakdown[itemId].alts[charName][sourceKey] or 0) + count
        else
            -- Current character or global source
            breakdown[itemId][sourceKey] = (breakdown[itemId][sourceKey] or 0) + count
        end
    end
end

-- How many items a source holds: for a debug line only (see ScanAll).
local function CountItems(items)
    local count = 0
    for _ in pairs(items) do count = count + 1 end
    return count
end

-- Is the Syndicator addon there to read stock from?
function Inventory:UsesSyndicator()
    return (Syndicator and Syndicator.API) and true or false
end

-- The memory must never stop the addon: a damaged saved table or a client
-- call that fails would otherwise break login or every scan. Its entry
-- points therefore run protected. A failure is not hidden: the first one of
-- a session is handed to the game's error handler, so the player's error
-- display shows it once (the debug log gets it too, but drops it while
-- debugging is off); every one is counted, and /lp diag stock prints the
-- last one, where it happened, how many there were and whether the memory
-- reads right now.
local memoryErrors = { count = 0, last = nil, where = nil }

-- Hand a message to the game's error handler, through the client adapter
-- (the handler is the client's). Nothing gets out of here: this runs where a
-- failure is being noted, and noting one must not be the next failure.
local function ShowError(message)
    local Client = LazyProf.Client
    if Client then
        pcall(Client.ShowError, Client, message)
    end
end

local function NoteMemoryError(where, err)
    memoryErrors.count = memoryErrors.count + 1
    memoryErrors.last = tostring(err)
    memoryErrors.where = where
    if memoryErrors.count == 1 then
        local message = "LazyProf: its memory of your stock failed (" .. where .. "): " .. tostring(err)
        LazyProf:Debug("pathfinder", message)
        ShowError(message .. " - bank and alt stock may be missing from the lists; /lp diag stock says more.")
    end
end

-- Run fn(...) protected. Returns whether it ran through, then its first result.
local function Protected(where, fn, ...)
    local ok, result = pcall(fn, ...)
    if not ok then
        NoteMemoryError(where, result)
        return false, nil
    end
    return true, result
end

-- The addon's own Self-Found setting (per character, off by default).
local function SelfFoundSetting()
    local char = LazyProf.db and LazyProf.db.char
    return (char and char.selfFoundMode) and true or false
end

-- A Self-Found character can neither be sent anything nor send anything:
-- nothing of the other characters is counted for it, and what it holds is
-- not offered to them (every save of its stock says so). It is one when the
-- setting is on or the game itself marks it (the adapter's answer, asked at
-- every call and never kept: a scan made under the other answer must not
-- serve). A scan asks this outside the memory's protected part, so the
-- adapter's call runs protected here: when it fails the setting alone
-- decides, and the failure is counted like every other.
local function IsSelfFound()
    if SelfFoundSetting() then return true end
    local Client = LazyProf.Client
    local asked, marked = Protected("game flag", Client.IsSelfFoundCharacter, Client)
    return asked and marked == true
end

-- What a save says of the character: whether it can send. What is saved is
-- offered to the other characters, so a flag that cannot be read says that
-- it cannot (the failure is counted like every other).
local function CanSend()
    if SelfFoundSetting() then return false end
    local Client = LazyProf.Client
    local asked, marked = Protected("game flag", Client.IsSelfFoundCharacter, Client)
    return asked and marked ~= true
end

-- Defined with the bank's rules further down ("Keeping the memory").
local BankPending       -- is the open bank of that kind left out of a scan right now (rule 3)?
local RisenAfterClose   -- which banks a scan leaves out for a carried count that rose after a close (rule 5b)
local SettleAfterClose  -- the comparison due after a carried bag's update that followed a close (rule 5b)
local AwaitsLastSession -- is that bank left out until the bags are compared with the last session's note (rule 5c)?
local HeldAfterClose    -- is that bank left out for the second after its close (rule 4)?

-- The account bank as it counts for the character `identity`: its items,
-- when it was seen and whether it is in doubt - nil when nothing is
-- remembered of it, or the copy remembered is of another world or faction's
-- read (it is then not counted for this character at all).
local function AccountBankOf(identity)
    local items, seenAt, doubt, world, faction = LazyProf.StockMemory:AccountBank(identity.region)
    if not items or identity.world == nil or world ~= identity.world or faction ~= identity.faction then return nil end
    return items, seenAt, doubt
end

-- Is the account bank of the character's region left out for this reason
-- alone: its copy holds at least one item and was read on a character of
-- another world or of the other faction? (Not when the character's own
-- world or faction is unknown: that is another reason.)
local function AccountReadElsewhere(identity)
    if identity.world == nil or identity.faction == nil then return false end
    local items, _, _, world, faction = LazyProf.StockMemory:AccountBank(identity.region)
    return items ~= nil and next(items) ~= nil and (world ~= identity.world or faction ~= identity.faction)
end

-- Frame-level cache: ScanAll is called many times per frame (once per recipe in
-- GetCandidates). Cache results so only the first call per frame does real work.
local scanCache = { time = 0, combined = nil, breakdown = nil, meta = nil }

-- Stock from Syndicator: the character's bank, mail and auctions, the alts,
-- the guild bank (the last two not for a Self-Found character: selfFound,
-- as the scan found it). logLines: build the lines for the debug log.
local function AddSyndicatorStock(self, combined, breakdown, countAlts, selfFound, logLines)
    local charName = Syndicator.API.GetCurrentCharacter()
    local charData = charName and Syndicator.API.GetByCharacterFullName(charName)

    if charData then
        for _, source in ipairs(PER_CHAR_SOURCES) do
            if not source.configKey or LazyProf.db.profile[source.configKey] then
                local scanMethod = "Scan" .. source.key:sub(1,1):upper() .. source.key:sub(2)
                local items = self[scanMethod](self, charData)
                mergeSource(items, source.key, nil, combined, breakdown)

                if logLines then
                    LazyProf:Debug("pathfinder", string.format("Inventory scan: %d unique items in %s", CountItems(items), source.key))
                end
            elseif logLines then
                LazyProf:Debug("pathfinder", "Inventory scan: " .. source.key .. " disabled")
            end
        end
    end

    -- Alt characters (if enabled, and the character can be sent things)
    if countAlts then
        local currentChar = Syndicator.API.GetCurrentCharacter()
        local allChars = Syndicator.API.GetAllCharacters()
        local totalAltItems = 0

        if allChars then
            for _, altName in ipairs(allChars) do
                if altName ~= currentChar then
                    local altData = Syndicator.API.GetByCharacterFullName(altName)
                    if altData then
                        -- Bags
                        local altBags = self:ScanBagsSyndicator(altData)
                        mergeSource(altBags, "bags", altName, combined, breakdown)

                        -- Bank, mail, auctions (respecting config for bank)
                        for _, source in ipairs(PER_CHAR_SOURCES) do
                            if not source.configKey or LazyProf.db.profile[source.configKey] then
                                local scanMethod = "Scan" .. source.key:sub(1,1):upper() .. source.key:sub(2)
                                local items = self[scanMethod](self, altData)
                                mergeSource(items, source.key, altName, combined, breakdown)
                            end
                        end

                        if logLines then
                            totalAltItems = totalAltItems + CountItems(altBags)
                        end
                    end
                end
            end
        end

        if logLines then
            LazyProf:Debug("pathfinder", string.format("Inventory scan: %d unique items from alts", totalAltItems))
        end
    elseif logLines then
        LazyProf:Debug("pathfinder", "Inventory scan: alts not counted")
    end

    -- Guild bank (if enabled). It is other characters' stock as well: a
    -- Self-Found character, which cannot be handed anything, does not count it.
    if LazyProf.db.profile.includeGuildBank and not selfFound then
        local guildItems = self:ScanGuildBank()
        mergeSource(guildItems, "guildBank", nil, combined, breakdown)

        if logLines then
            LazyProf:Debug("pathfinder", string.format("Inventory scan: %d unique items in guild bank", CountItems(guildItems)))
        end
    elseif logLines then
        LazyProf:Debug("pathfinder", "Inventory scan: guild bank disabled")
    end
end

-- The alts' part of a scan, kept between scans. Building it copies every
-- alt's stock, and the light refresh scans up to three times a second while
-- crafting. It depends on who the character is (its id, and the world and
-- faction it is of right now - the world is read again at every ask and can
-- differ from the one read at login), on whether banks count and on the other
-- characters' saved records - so it is kept under those and built again when
-- any of them differs, when the saved table was replaced as a whole, and when
-- the other characters changed (Forget, and dropping old ones at the start).
-- What the character itself saves does not touch it. Its tables are handed to
-- every scan as they are: read them, do not change them.
--   { guid, world, faction, countBank, token,
--     totals  = { [itemId] = count over all alts },
--     sources = { [itemId] = { [name] = { bags, bank } } },
--     seen    = { [name] = { bags = time, bank = time } },
--     bankDoubt = { name, ... } }   the alts whose bank is in doubt and so
--                                   left out, by name (only while banks count)
local altsPart = nil

local function BuildAltsPart(identity, countBank)
    local part = { guid = identity.guid, world = identity.world, faction = identity.faction, countBank = countBank,
                   totals = {}, sources = {}, seen = {}, bankDoubt = {} }
    local where = {}
    -- The memory hands the alts out by name, so bankDoubt is in that order.
    -- A part whose time is damaged is not handed out (its bank is in doubt).
    for _, alt in ipairs(LazyProf.StockMemory:Alts(identity, LazyProf.Client:Now())) do
        local seen = {}
        if alt.bags then
            mergeSource(alt.bags, "bags", alt.name, part.totals, where)
            seen.bags = alt.bagsAt
        end
        if countBank and alt.bank then
            mergeSource(alt.bank, "bank", alt.name, part.totals, where)
            seen.bank = alt.bankAt
        elseif countBank and alt.bankDoubt then
            part.bankDoubt[#part.bankDoubt + 1] = alt.name
        end
        part.seen[alt.name] = seen
    end
    for itemId, entry in pairs(where) do
        part.sources[itemId] = entry.alts
    end
    return part
end

-- The alts' part for this character and setting: the kept one, or a new one.
local function AltsPart(identity, countBank)
    local token = LazyProf.StockMemory:Token()
    local part = altsPart
    if part and token ~= nil and part.token == token and part.guid == identity.guid
            and part.world == identity.world and part.faction == identity.faction and part.countBank == countBank then
        return part
    end
    part = BuildAltsPart(identity, countBank)
    part.token = token
    -- Kept only once the character is fully known: before that nothing is
    -- an alt, and that answer must not stick.
    local known = identity.guid and identity.name and identity.world and identity.faction
    altsPart = (token ~= nil and known) and part or nil
    return part
end

-- The other characters' saved records changed: build the alts' part anew.
function Inventory:ForgetAltsPart()
    altsPart = nil
end

-- Stock from LazyProf's own memory. Returns how old each part is:
--   { remembered = true,
--     bankSeenAt     when the character's bank was seen (nil: never, or not counted)
--     accountSeenAt  when the account bank was seen (counted only when that
--                    read was one of this world and faction)
--     bankInDoubt    true when the character's bank is remembered but in doubt
--     accountInDoubt true when the account bank is (of a read of this world
--                    and faction: one read elsewhere is not counted at all)
--     bankPending    true when the character's bank is left out because it
--                    is open and unsettled, a read is owed or its empty read
--                    is not believed yet: a read is on its way; or because
--                    it could not be read back at the close and is held
--                    for a second; or because a carried count rose after
--                    its close and the comparison is still to come; or
--                    because the bags have
--                    not been compared yet with what they held when the
--                    last session ended at the bank
--     accountPending the same for the account bank
--     accountElsewhere true when the account bank is not counted because
--                    its copy, which holds items, was read on a character
--                    of another world or of the other faction (set only
--                    while bank items count for this character at all)
--     altBanksInDoubt  { name, ... }: the alts whose bank is in doubt and so
--                    left out, by name; nil when there is none (or alts or
--                    bank items do not count)
--     alts = { [name] = { bags = time, bank = time } } }   the alts counted
-- The character's own bank and the account bank are both bank stock (the
-- account bank is other characters' stock too, so a character that cannot
-- receive anything does not count it). An alt's bank needs both settings.
-- A bank in doubt (rule 6 at the top of this file) is not counted: not the
-- character's own, not the account bank, and not an alt's (its bags still
-- are). Nor is the open bank while it is unsettled or a read of it is owed
-- (rule 3), nor a bank that is held after its close (rule 4), nor a bank
-- named in leaveOut ({ [kind] = true }, rule 5b), nor a bank that waits for
-- the comparison with the last session's note (rule 5c).
-- The marks are only set for a bank that would count otherwise. Nothing is
-- read from the client here and nothing is written: whether the character is
-- Self-Found is handed in (selfFound), as the caller found it.
local function AddRememberedStock(self, combined, breakdown, countAlts, selfFound, leaveOut)
    local Memory, Client = LazyProf.StockMemory, LazyProf.Client
    local countBank = LazyProf.db.profile.includeBankItems and true or false
    local identity = Client:CharacterIdentity() or {}
    local meta = { remembered = true, alts = {} }
    local now = Client:Now()

    if countBank then
        -- A bank whose time read back is damaged (StockMemory.SoundTime) is
        -- left out as a bank in doubt is: nothing says what it holds is of
        -- this side of anything.
        local items, seenAt, doubt = Memory:OwnBank(identity.guid)
        doubt = doubt or (items ~= nil and not Memory.SoundTime(seenAt, now))
        if items and doubt then
            meta.bankInDoubt = true
        elseif items and (BankPending("character") or HeldAfterClose("character") or (leaveOut and leaveOut.character)
                or AwaitsLastSession("character", identity)) then
            meta.bankPending = true
        elseif items then
            mergeSource(items, "bank", nil, combined, breakdown)
            meta.bankSeenAt = seenAt
        end
        if not selfFound then
            items, seenAt, doubt = AccountBankOf(identity)
            doubt = doubt or (items ~= nil and not Memory.SoundTime(seenAt, now))
            if items and doubt then
                meta.accountInDoubt = true
            elseif items and (BankPending("account") or HeldAfterClose("account") or (leaveOut and leaveOut.account)
                    or AwaitsLastSession("account", identity)) then
                meta.accountPending = true
            elseif items then
                mergeSource(items, "bank", nil, combined, breakdown)
                meta.accountSeenAt = seenAt
            elseif AccountReadElsewhere(identity) then
                meta.accountElsewhere = true
            end
        end
    end

    if countAlts then
        local part = AltsPart(identity, countBank)
        for itemId, count in pairs(part.totals) do
            combined[itemId] = (combined[itemId] or 0) + count
            local entry = breakdown[itemId]
            if not entry then
                entry = {}
                breakdown[itemId] = entry
            end
            entry.alts = part.sources[itemId]
        end
        meta.alts = part.seen
        if #part.bankDoubt > 0 then
            meta.altBanksInDoubt = part.bankDoubt
        end
    end
    return meta
end

-- The memory's part of a scan. While a comparison is due after a close
-- (rule 5b), the bags the scan has just read say which banks it leaves out -
-- so that no scan counts a bank beside the items that have just come out of
-- it. The bank itself is never read here, and nothing is marked.
local function ScanMemory(self, combined, breakdown, countAlts, selfFound, bagItems, backpackSlots)
    local leaveOut = nil
    if backpackSlots and backpackSlots > 0 then
        leaveOut = RisenAfterClose(bagItems)
    end
    return AddRememberedStock(self, combined, breakdown, countAlts, selfFound, leaveOut)
end

-- Scan all inventory sources based on settings
-- Returns: combinedInventory, sourceBreakdown, meta
--   combinedInventory  { [itemId] = count } over every source that counts
--   sourceBreakdown    { [itemId] = { bags, bank, mail, auctions, guildBank,
--                        alts = { [name] = { bags, bank, mail, auctions } } } }
--   meta               how old the remembered parts are (AddRememberedStock);
--                      nil when the stock comes from Syndicator
function Inventory:ScanAll()
    -- Return cached results if called again in the same frame, unless a
    -- setting that decides which stock counts has changed since
    local now = GetTime()
    local profile = LazyProf.db.profile
    local countBank = profile.includeBankItems and true or false
    local wantAlts = profile.includeAltCharacters and true or false
    local countGuild = profile.includeGuildBank and true or false
    local selfFound = IsSelfFound()
    if scanCache.combined and scanCache.time == now and scanCache.countBank == countBank
            and scanCache.wantAlts == wantAlts and scanCache.countGuild == countGuild
            and scanCache.selfFound == selfFound then
        return scanCache.combined, scanCache.breakdown, scanCache.meta
    end

    local combined = {}
    local breakdown = {}
    local meta = nil
    -- The lines for the debug log - counting each source's items, a
    -- formatted line per source - are built only while that log takes them:
    -- a scan runs for every calculation and for every light refresh.
    local logLines = LazyProf:IsDebugEnabled("pathfinder")

    -- 1. Current character bags (read live, always on)
    local bagItems, _, backpackSlots = self:ScanBags()
    mergeSource(bagItems, "bags", nil, combined, breakdown)

    if logLines then
        LazyProf:Debug("pathfinder", string.format("Inventory scan: %d unique items in bags", CountItems(bagItems)))
    end

    -- 2. Everything outside the bags
    local countAlts = wantAlts and not selfFound
    if self:UsesSyndicator() then
        AddSyndicatorStock(self, combined, breakdown, countAlts, selfFound, logLines)
    else
        local ok, result = Protected("scan", ScanMemory, self, combined, breakdown, countAlts, selfFound, bagItems, backpackSlots)
        if ok then
            meta = result
        else
            -- The memory could not be read: count what is carried, nothing else.
            combined, breakdown = {}, {}
            mergeSource(bagItems, "bags", nil, combined, breakdown)
            meta = { remembered = true, alts = {} }
        end
    end

    scanCache.time = now
    scanCache.combined = combined
    scanCache.breakdown = breakdown
    scanCache.meta = meta
    scanCache.countBank, scanCache.wantAlts = countBank, wantAlts
    scanCache.countGuild, scanCache.selfFound = countGuild, selfFound

    return combined, breakdown, meta
end

-- Forget this frame's scan: what the character itself holds has changed.
local function InvalidateFrame()
    scanCache.time = 0
    scanCache.combined = nil
    scanCache.breakdown = nil
    scanCache.meta = nil
end

-- Invalidate the ScanAll cache (call when inventory or a stock setting
-- changes mid-frame). The alts' part is not dropped by this: it is kept under
-- what it depends on (see AltsPart).
function Inventory:InvalidateCache()
    InvalidateFrame()
end

-- ============================================================================
-- Keeping the memory
-- Nothing here plans the path again; a change of what is remembered only
-- asks the shown list to redraw. With Syndicator installed none of it does
-- anything. The rules are at the top of this file.
-- ============================================================================

local BAG_SAVE_DELAY = 2
local BANK_SETTLE = 0.5         -- the second look, this long after the opening
local BANK_EMPTY_TRUST = 2      -- an empty bank is not believed earlier after the opening
local BANK_READ_SPACING = 0.2   -- least time between two reads that changes ask for
local CLOSE_WATCH = 1           -- how long after the close a carried count that rose is taken for a late answer
local CLOSE_WATCH_BLIND = 3     -- the same after a close at which a bank of the visit could not be looked at
local CLOSE_WATCH_BANK = 10     -- how long after the close a session that ends leaves its note (rule 5c)
local LOGIN_QUIET = 10          -- how long after the start of a session a bank-container update is only counted
local CLOCK_SLACK = 0.001       -- a timer may run a hair before its mark
local BANK_KINDS = { "character", "account" }

-- First-wins debounces on a pending flag (C_Timer.After returns nothing).
local bagSavePending = false
local bagUpdateSeen = false     -- a bag update asked for the waiting save

-- The bank visit in progress, or the last one (kept for /lp diag stock):
--   openedAt, closedAt   GetTime() of the opening and of the close
--   lastReadAt           GetTime() of the last read; GetTime() is the same
--                        all through a frame, so it also names the frame
--   reads                how many reads were taken
--   owed                 an update (of any container) arrived after the last
--                        read: a read is waiting for the spacing
--   confirm              an empty read waits for its second look
--   trailingPending      the trailing read's timer is waiting
--   lookPending[mark]    the look `mark` seconds after the opening is waiting
--   reopened             how many opening notices came again during the visit
--   closing              what the closing notice did (see CloseVisit)
--   character, account   per bank:
--     slots      slot count of the last read kept
--     keptItems  a read with items was kept
--     emptyAt    frame of the first empty read not believed yet (unresolved)
--                since the bank's last own update
--     usable     the adapter called the bank usable at some read of this visit
--     unsettled  an update of one of its containers (or a change of its
--                tabs, or an opening notice that came again) arrived that no
--                kept read of it has come after
--     lockSeen   the last kept read saw a slot of it locked, and no update
--                of its own containers has come since (rule 4)
--     kept       how many reads were kept
--     last       what the last read gave, in words
local visit = nil
local bankClosedAt = nil        -- GetTime() of the last close
-- The start of the session (Initialize), and whether it has had a visit.
local sessionStartedAt = GetTime()
local visitedThisSession = false
-- Bank containers' updates that arrived while the bank was closed: how
-- many, how long after the last close the last one came, how many came in
-- the quiet start of the session and how many marked a bank (rule 5a).
local closedBankUpdates = { count = 0, lastAfter = nil, quiet = 0, marked = 0 }
-- The watch after a close (rule 5):
--   at, guid, region  when the window closed, and whose banks the visit read
--   usable[kind]      the bank was usable in the visit: it can be marked
--   held[kind]        the bank could not be read back at the close: left out
--                     of the scans for CLOSE_WATCH (rule 4)
--   heldOver          the timer that ends CLOSE_WATCH for the held banks ran
--   note              the carried bags' contents at the closing notice (nil:
--                     they could not be read), lowered by each comparison
--                     to the counts that have fallen
--   floor             the same for the scans that come before a comparison:
--                     lowered by each of them, and set back to the note by
--                     the comparison
--   bankUpdates, bankLast   updates of bank containers inside the ten seconds
--                     after the close, and how long after it the last one came
--   bagUpdates, bagLast     the same for carried bags inside CLOSE_WATCH
--   watchFor[kind]    how long after the close a carried count that rose is
--                     a reason to mark that bank (rule 5b): CLOSE_WATCH, or
--                     CLOSE_WATCH_BLIND for a bank not looked at the close
--   owed, pending     a comparison is due; its timer is waiting
--   dueAt             when the carried bag's update came that made it due
--   scanLeftOut       a scan left a bank out for the comparison that is due
--   compared          how many comparisons were made
--   done[kind]        the remembered bank carries the doubt mark: nothing
--                     more to find out about it
--   marked[kind]      why this watch marked it
local watch = nil
-- The bags at the bank, as the character's last session left them noted
-- (rule 5c), or - when it left no note - as the character's last save of
-- them left them (rule 5d):
--   looked    the memory was asked for the note (once the character is known)
--   state     nil: there was none | "waiting": not compared yet | "equal" |
--             "different" | "unknown"
--   guid      whose note it is
--   note      the note (StockMemory:BagsAtBank); for the record of the bags
--             one of the same shape, which names both banks
--   started        the session was started (Initialize): only then is the
--                  record of the bags the one its last session left
--   fromRecord     the note is the record of the bags (rule 5d)
--   damaged        the note's (or the record's) time is damaged
--   marked[kind]   the comparison left that bank's record with the doubt mark
local lastSession = { looked = false, marked = {} }

-- Mark the remembered bank of that kind in doubt. Returns whether that
-- changed what is remembered (there is such a bank, and it was not marked),
-- and whether the remembered bank carries the mark now (false when nothing
-- is remembered of it: there is nothing to mark then).
-- The account bank is the copy of the character's region, whoever's read it
-- is (region).
local function MarkDoubt(kind, guid, region)
    local Memory = LazyProf.StockMemory
    if kind == "character" then
        if Memory:MarkBankDoubt(guid) then return true, true end
        return false, select(3, Memory:OwnBank(guid)) == true
    end
    if Memory:MarkAccountBankDoubt(region) then return true, true end
    return false, select(3, Memory:AccountBank(region)) == true
end

-- Rule 5c: the note the character's last session left, looked up once.
-- Rule 5d: without a note, the bags as the character's last save left them
-- (taken before this session's first save replaces them); compared like a
-- note that names both banks - which of them can be marked is decided when
-- they are compared.
local function LastSession(identity)
    local ls = lastSession
    if ls.looked then return ls end
    identity = identity or LazyProf.Client:CharacterIdentity() or {}
    if not identity.guid then return ls end
    ls.looked = true
    local Memory = LazyProf.StockMemory
    local note = Memory:BagsAtBank(identity.guid)
    if note then
        ls.state, ls.guid, ls.note = "waiting", identity.guid, note
    elseif ls.started then
        local items, at = Memory:OwnBags(identity.guid)
        if items then
            ls.state, ls.guid, ls.fromRecord = "waiting", identity.guid, true
            ls.note = { known = true, items = items, character = true, account = true, at = at }
        end
    end
    return ls
end

-- For a scan: that bank is left out until the bags have been compared.
AwaitsLastSession = function(kind, identity)
    local ls = LastSession(identity)
    return ls.state == "waiting" and ls.note[kind] == true
end

local function SameCounts(a, b)
    for itemId, count in pairs(a) do
        if b[itemId] ~= count then return false end
    end
    for itemId in pairs(b) do
        if a[itemId] == nil then return false end
    end
    return true
end

-- The item (the lowest id) whose carried count in `items` is above the note
-- and which the remembered bank `held` holds; nil when there is none.
local function RisenItem(note, items, held)
    local risen = nil
    for itemId, count in pairs(items) do
        if count > (note[itemId] or 0) and (held[itemId] or 0) > 0 and (risen == nil or itemId < risen) then
            risen = itemId
        end
    end
    return risen
end

-- Rule 5c: compare the bags with the last session's note and take the note
-- away. items: what the carried bags hold now; nil when that cannot be told
-- (they cannot be read, or cannot be trusted). A difference, a note that is
-- not known and bags that cannot be told mark the banks the note names.
local function CompareLastSession(items)
    local ls = lastSession
    if ls.state ~= "waiting" then return end
    local note = ls.note
    local Memory = LazyProf.StockMemory
    local now = LazyProf.Client:Now()
    -- A note whose time is damaged leans towards not counting: it is taken
    -- as not known, whatever the bags hold.
    local damaged = not Memory.SoundTime(note.at, now)
    if not note.known or not items or damaged then
        ls.state = "unknown"
        ls.damaged = damaged or nil
    elseif SameCounts(note.items, items) then
        ls.state = "equal"
    else
        ls.state = "different"
    end
    if ls.state ~= "equal" then
        -- The region is asked for now: it may not have been readable when
        -- the note was looked up. An account bank whose record was saved
        -- after the note was written (read by another character meanwhile)
        -- is newer than anything the note can be about: it is not marked by
        -- it - when both times are sound. Nothing but damage can make the
        -- character's own bank look saved after its own note: no exception
        -- for it.
        local identity = LazyProf.Client:CharacterIdentity() or {}
        for _, kind in ipairs(BANK_KINDS) do
            if note[kind] then
                local savedAt
                if kind == "account" then
                    savedAt = select(2, Memory:AccountBank(identity.region))
                end
                -- Bags that are only different, not risen for an item the
                -- bank holds: no answer of a withdrawal from it can have
                -- landed after the session (a deposit's answer is seen on
                -- its way at the close: its carried slot is locked), so
                -- the difference is the new session's own (a craft, a sale).
                local held
                if kind == "character" then
                    held = Memory:OwnBank(ls.guid)
                elseif not ls.fromRecord then
                    held = Memory:AccountBank(identity.region)
                elseif not IsSelfFound() and Memory:ReadsAccountBank(ls.guid) then
                    -- Rule 5d: only the account bank this character counts,
                    -- and only when it has read it before: a character that
                    -- may not view it cannot have changed it, and could
                    -- never read it to take the mark away.
                    held = AccountBankOf(identity)
                end
                if ls.fromRecord and not (held and next(held) ~= nil) then
                    -- Rule 5d: nothing of it counts here, or nothing is in it.
                elseif not ls.fromRecord and kind == "account" and not damaged and Memory.SoundTime(savedAt, now)
                        and savedAt > note.at then
                    ls.newer = ls.newer or {}
                    ls.newer[kind] = true
                elseif ls.state == "unknown" or (held and RisenItem(note.items, items, held)) then
                    local _, marked = MarkDoubt(kind, ls.guid, identity.region)
                    ls.marked[kind] = marked or nil
                else
                    ls.notRisen = ls.notRisen or {}
                    ls.notRisen[kind] = true
                end
            end
        end
    end
    LazyProf.StockMemory:ClearBagsAtBank(ls.guid)
    -- The banks count again, or are in doubt now: either way another scan.
    InvalidateFrame()
    if LazyProf.ScheduleShoppingListRefresh then
        LazyProf:ScheduleShoppingListRefresh()
    end
end

-- Rule 5c: the bags, when they are a read to compare with: backpack slots,
-- and - when they hold nothing at all - a bag update before the read
-- (trustEmpty). nil otherwise.
local function BagsToCompare(trustEmpty)
    local items, _, backpackSlots = LazyProf.Client:BagContents()
    if not backpackSlots or backpackSlots <= 0 then return nil end
    if not trustEmpty and next(items) == nil then return nil end
    return items
end

-- Rule 5c: when the session began with a note that has not been compared
-- yet, compare now, with whatever can be told of the bags. Bags that read
-- as completely empty without a bag update before them are a read only
-- when the note says the bags were empty too: what is read agrees with it.
local function CompareWaiting(trustEmpty)
    local ls = LastSession()
    if ls.state ~= "waiting" then return end
    local note = ls.note
    local agrees = note.known and type(note.items) == "table" and next(note.items) == nil
    CompareLastSession(BagsToCompare(trustEmpty or agrees))
end

-- `counts` less what is in `part` (none below zero).
local function Without(counts, part)
    local left = {}
    for itemId, count in pairs(counts) do
        local rest = count - (part[itemId] or 0)
        if rest > 0 then left[itemId] = rest end
    end
    return left
end

-- Remember what the character carries. trustEmpty: a bag update came before
-- this read, so bags without a single item are really empty. A slot whose
-- move is on its way (it reads as locked) is left out: until the move is
-- answered it shows what it held before the click, which may be on its way
-- into another slot that is already reported, and what is saved is offered
-- to the other characters. Returns whether it was saved.
function Inventory:SaveBags(trustEmpty)
    if self:UsesSyndicator() then return false end
    -- Rule 5d: the record of the bags this save replaces is taken first.
    LastSession()
    local Client = LazyProf.Client
    local items, bound, backpackSlots, locked = Client:BagContents()
    if not backpackSlots or backpackSlots <= 0 then
        return false   -- the bags could not be read just now
    end
    if not trustEmpty and next(items) == nil then
        return false   -- slots but no items, and nothing says they are loaded
    end
    if type(locked) == "table" and next(locked) ~= nil then
        items = Without(items, locked)
        -- Which of the locked ones were soulbound is not told: what is left
        -- keeps as much soulbound as it can hold (so no more is offered).
        local capped = {}
        for itemId, count in pairs(bound) do
            if items[itemId] then capped[itemId] = math.min(count, items[itemId]) end
        end
        bound = capped
    end
    return LazyProf.StockMemory:SaveBags(Client:CharacterIdentity(), items, bound, Client:Now(), CanSend())
end

local ArmBagSave

-- Can the character be told apart right now (its id read)? A failure of the
-- call counts as yes: what follows then fails for itself and is counted, and
-- nothing is tried again for ever.
local function IdentityReadable()
    local Client = LazyProf.Client
    local ok, identity = Protected("bag save", Client.CharacterIdentity, Client)
    return not ok or (type(identity) == "table" and identity.guid ~= nil)
end

-- The save a request asked for, BAG_SAVE_DELAY later. While the character's
-- id cannot be read it is asked for again, BAG_SAVE_DELAY after that: the
-- bags cannot be saved without it, and the comparison with the last
-- session's note (rule 5c) waits for it too.
local function TimedBagSave()
    if not bagSavePending then return end   -- written at logout meanwhile
    if not IdentityReadable() then
        if not Protected("bag save", ArmBagSave) then
            bagSavePending = false
        end
        return
    end
    bagSavePending = false
    local trustEmpty = bagUpdateSeen
    bagUpdateSeen = false
    -- Rule 5c: by the first save of a session the bags are compared
    -- with the last session's note, with whatever can be told by now.
    Protected("bag save", CompareWaiting, trustEmpty)
    Protected("bag save", Inventory.SaveBags, Inventory, trustEmpty)
end

ArmBagSave = function()
    C_Timer.After(BAG_SAVE_DELAY, TimedBagSave)
end

-- fromUpdate: asked for by a bag update (see SaveBags).
-- Setting the timer runs protected: a client without timers, or a timer call
-- that fails, must not raise into whoever asked (the start of the addon
-- among them). The waiting flag does not stay set then - no timer would ever
-- clear it, and it would turn every later request away.
function Inventory:RequestBagSave(fromUpdate)
    if self:UsesSyndicator() then return end
    if fromUpdate then
        bagUpdateSeen = true
    end
    if bagSavePending then return end
    bagSavePending = true
    if not Protected("bag save", ArmBagSave) then
        bagSavePending = false
    end
end

-- The bank -------------------------------------------------------------------

local function NewVisit()
    local v = { openedAt = GetTime(), reads = 0, owed = false, confirm = false, trailingPending = false, lookPending = {} }
    for _, kind in ipairs(BANK_KINDS) do
        v[kind] = { kept = 0, keptItems = false, usable = false, unsettled = false }
    end
    return v
end

-- The visit in progress; nil while the bank is closed. A bank that counts as
-- open without its opening having been reported begins a visit here.
local function OpenVisit()
    if not LazyProf.Client:IsBankOpen() then return nil end
    if not visit or visit.closedAt then
        visit = NewVisit()
    end
    return visit
end

-- Rule 3, for a scan: is the open bank of that kind left out right now? An
-- unsettled bank is, so is either bank while a read is owed, a bank whose
-- empty read is not believed yet, and a bank whose last read was refused -
-- when it was usable in this visit.
BankPending = function(kind)
    local v = visit
    if not v or v.closedAt or v.closing then return false end
    local state = v[kind]
    return state.usable and (state.unsettled or v.owed or state.emptyAt ~= nil or state.refused) and true or false
end

-- Does the memory hold items for that bank (the account bank: the copy of
-- the region, whoever's read it is)?
local function RemembersItems(kind, identity)
    local Memory = LazyProf.StockMemory
    local items
    if kind == "character" then
        items = Memory:OwnBank(identity.guid)
    else
        items = Memory:AccountBank(identity.region)
    end
    return items ~= nil and next(items) ~= nil
end

local function SaveBank(kind, identity, items, bound, now)
    if kind == "character" then
        return LazyProf.StockMemory:SaveBank(identity, items, bound, now, CanSend())
    end
    return LazyProf.StockMemory:SaveAccountBank(identity, items, now)
end

-- One read of the open bank, both kinds, keeping what rule 2 allows (rule 4
-- for the read at the closing notice: `closing`, which also has the kinds it
-- kept noted in keptNow). Returns whether what is remembered changed.
-- Whether a bank is left out may be different after any read, so the frame's
-- scan is dropped first.
local function ReadBank(v, closing, keptNow)
    local Client = LazyProf.Client
    InvalidateFrame()
    local identity = Client:CharacterIdentity() or {}
    local now, frame = Client:Now(), GetTime()
    local late = frame - v.openedAt >= BANK_EMPTY_TRUST - CLOCK_SLACK
    v.lastReadAt = frame
    v.reads = v.reads + 1
    v.owed = false
    v.confirm = false
    local changed = false
    for _, kind in ipairs(BANK_KINDS) do
        local state = v[kind]
        -- Asked at every read: usable once is enough for the visit.
        if Client:BankUsable(kind) then
            state.usable = true
        end
        local items, bound, slots, locked = Client:BankContents(kind)
        local keep = false
        state.refused = not items
        if not items then
            state.last = "refused"
        elseif next(items) ~= nil then
            keep = not closing or (state.slots ~= nil and slots == state.slots)
            state.last = keep and "items" or "items, another slot count"
        elseif closing then
            -- Never believed from this read: the client may have let go of
            -- the bank already. It makes no empty read unresolved either.
            state.last = "empty"
        else
            local remembered = RemembersItems(kind, identity)
            local sameBank = state.keptItems and state.slots == slots
            local secondLook = state.emptyAt ~= nil and state.emptyAt < frame
            if not remembered then
                keep = late and (secondLook or not state.unsettled)
            else
                keep = (late or sameBank) and secondLook
            end
            if keep then
                state.last = "empty, believed"
            else
                -- Not believed, so not kept: the bank is unresolved from
                -- here on, and when it was unsettled it stays so.
                state.last = "empty, not believed"
                state.emptyAt = state.emptyAt or frame
                -- Only the second look is missing: it comes with the trailing read.
                if (remembered and (late or sameBank)) or (not remembered and late) then
                    v.confirm = true
                end
            end
        end
        if keep then
            if SaveBank(kind, identity, items, bound, now) then
                state.slots = slots
                state.emptyAt = nil
                state.unsettled = false
                -- Whether this read saw a slot that reads as locked: a move
                -- of it on its way, until an update of this bank's own
                -- containers or a later kept read without one (rule 4).
                state.lockSeen = type(locked) == "table" and next(locked) ~= nil or nil
                state.kept = state.kept + 1
                if next(items) ~= nil then
                    state.keptItems = true
                end
                if keptNow then
                    keptNow[kind] = true
                end
                changed = true
            else
                state.last = state.last .. ", not saved"
            end
        end
    end
    return changed
end

local LookAtBank

-- The look `mark` seconds after this visit's opening; one per mark is waiting
-- at most. A visit that is over by then is not looked at, nor is one that
-- has had a read since that mark (another timer of the same moment).
local function ScheduleLook(v, mark)
    if v.lookPending[mark] then return end
    v.lookPending[mark] = true
    C_Timer.After(math.max(0, v.openedAt + mark - GetTime()), function()
        v.lookPending[mark] = nil
        if visit ~= v or v.closedAt then return end
        if v.lastReadAt and v.lastReadAt >= v.openedAt + mark - CLOCK_SLACK then return end
        Protected("bank read", LookAtBank, Inventory)
    end)
end

-- The trailing read: BANK_READ_SPACING after the last read, when a read is
-- owed or an empty read waits for its second look by then. One is waiting at
-- most; a read taken meanwhile moves it on.
local function ScheduleTrailing(v)
    if v.trailingPending then return end
    v.trailingPending = true
    local function fire()
        if visit ~= v or v.closedAt then
            v.trailingPending = false
            return
        end
        local wait = (v.lastReadAt or 0) + BANK_READ_SPACING - GetTime()
        if wait > CLOCK_SLACK then
            C_Timer.After(wait, fire)
            return
        end
        v.trailingPending = false
        if v.owed or v.confirm then
            Protected("bank read", LookAtBank, Inventory)
        end
    end
    C_Timer.After(math.max(0, (v.lastReadAt or GetTime()) + BANK_READ_SPACING - GetTime()), fire)
end

-- Does a bank of the visit want another read: usable in it, and unsettled,
-- with an empty read not believed yet, or refused at its last read? Nothing
-- else would read it again before something changes, and a scan leaves it
-- out meanwhile (rule 3) - or a refused bank stays as last kept while it
-- may have changed.
local function WantsAnotherLook(v)
    for _, kind in ipairs(BANK_KINDS) do
        local state = v[kind]
        if state.usable and (state.unsettled or state.emptyAt ~= nil or state.refused) then return true end
    end
    return false
end

-- Read again BANK_SETTLE after the last read while a bank wants another
-- look; one timer at most (a pending flag), moved on by any read taken
-- meanwhile. A visit that is over by then is not read.
local function ScheduleRepeat(v)
    if v.repeatPending then return end
    v.repeatPending = true
    local function fire()
        if visit ~= v or v.closedAt or v.closing then
            v.repeatPending = false
            return
        end
        local wait = (v.lastReadAt or 0) + BANK_SETTLE - GetTime()
        if wait > CLOCK_SLACK then
            C_Timer.After(wait, fire)
            return
        end
        v.repeatPending = false
        if WantsAnotherLook(v) then
            Protected("bank read", LookAtBank, Inventory)
        end
    end
    C_Timer.After(math.max(0, (v.lastReadAt or GetTime()) + BANK_SETTLE - GetTime()), fire)
end

-- Read the open bank now and ask for what the read leaves open: the second
-- look at an empty bank, another read of a bank that wants one. A shown list
-- is asked to redraw when the read changed what is remembered. Returns
-- whether it did.
LookAtBank = function(self)
    local v = OpenVisit()
    if not v then return false end
    local changed = ReadBank(v, false)
    if v.confirm then
        ScheduleTrailing(v)
    end
    if WantsAnotherLook(v) then
        ScheduleRepeat(v)
    end
    if changed and LazyProf.ScheduleShoppingListRefresh then
        LazyProf:ScheduleShoppingListRefresh()
    end
    return changed
end

-- Something changed while the bank is open (a bag update, a change of its
-- tabs): read it now when the last read is long enough ago, else the read is
-- owed and the trailing read takes it. kind: the bank whose container was
-- updated or whose tabs changed ("character" | "account"); nil for a carried
-- bag.
function Inventory:OnBankChange(kind)
    if self:UsesSyndicator() then return end
    local v = OpenVisit()
    if not v then return end
    -- That bank is unsettled from here until a read of it is kept (the read
    -- below, taken in this very call, comes after the update). An empty read
    -- from before this update is no first look for one after it (rule 2).
    -- Which banks a scan leaves out may change with that, so the frame's
    -- scan is dropped.
    if kind and v[kind] then
        v[kind].unsettled = true
        v[kind].emptyAt = nil
    end
    InvalidateFrame()
    if v.lastReadAt == nil or GetTime() - v.lastReadAt >= BANK_READ_SPACING - CLOCK_SLACK then
        LookAtBank(self)
    else
        v.owed = true
        ScheduleTrailing(v)
    end
end

function Inventory:OnBankOpened()
    if self:UsesSyndicator() then return end
    -- A second opening notice while the bank is open (the banker clicked
    -- again) begins no visit of its own: the visit keeps what it knows -
    -- which bank was usable, which is unsettled, which was refused, what its
    -- reads saw - and both banks are unsettled from here, as by an update of
    -- each one's own containers, until a read of each is kept (rule 3).
    local v = visit
    if v and not v.closedAt and not v.closing then
        Protected("bank read", function()
            for _, kind in ipairs(BANK_KINDS) do
                v[kind].unsettled = true
                v[kind].emptyAt = nil
            end
            v.reopened = (v.reopened or 0) + 1
            InvalidateFrame()
            if v.lastReadAt == nil or GetTime() - v.lastReadAt >= BANK_READ_SPACING - CLOCK_SLACK then
                LookAtBank(self)
            else
                v.owed = true
                ScheduleTrailing(v)
            end
        end)
        return
    end
    -- A comparison still due from the last close is made before its watch ends.
    if watch and watch.owed then
        Protected("bank close", SettleAfterClose)
    end
    watch = nil
    -- So is the one with the last session's note (rule 5c): a mark set
    -- later would fall on a bank this visit has just read.
    Protected("bank read", CompareWaiting, bagUpdateSeen)
    visit = NewVisit()
    visitedThisSession = true
    Protected("bank read", LookAtBank, self)
    ScheduleLook(visit, BANK_SETTLE)
    ScheduleLook(visit, BANK_EMPTY_TRUST)
end

-- Rule 4, at the adapter's closing notice and at a logout with the bank
-- open; once per visit. visit.closing says afterwards what was done:
--   owed               a read was owed
--   unsettled[kind]    the kind was unsettled when the notice came
--   read               the bank was read once more
--   kept[kind]         that read was kept for the kind
--   doubt[kind]        the kind was still unsettled, or a move was on its
--                      way: its remembered bank carries the doubt mark
--   held[kind]         the kind could not be read back and is held for a
--                      second (see rule 4)
--   moveInFlight       a slot read as locked: true, false, or "unknown" when
--                      the locks could not be read (taken for true)
-- It also takes the note of the carried bags for the watch after the close.
local function CloseVisit(self)
    local v = OpenVisit()
    if not v or v.closing then return end
    local Client = LazyProf.Client
    local done = { owed = v.owed, unsettled = {}, read = false, kept = {}, doubt = {}, held = {} }
    v.closing = done
    local readAgain = v.owed
    for _, kind in ipairs(BANK_KINDS) do
        if v[kind].unsettled then
            done.unsettled[kind] = true
            readAgain = true
        end
    end
    local changed = false
    if readAgain then
        -- Protected on its own: a read that fails is a read that kept
        -- nothing, and what follows must still be done.
        done.read = true
        local _, kept = Protected("bank close", ReadBank, v, true, done.kept)
        changed = kept and true or false
    end
    -- A move whose answer has not come: the client locks its slots from the
    -- click until the answer. Locks that cannot be read are taken for one.
    local asked, answer = Protected("bank close", function()
        local locked, looked = Client:MoveInFlight()
        return { locked = locked, looked = looked }
    end)
    -- So is a lock a kept read of this visit saw and that no update of that
    -- bank's own containers answered since: the bank may not be readable
    -- now, and its part of the move may never be reported after the close.
    local lockSeen = false
    for _, kind in ipairs(BANK_KINDS) do
        if v[kind].lockSeen then lockSeen = true end
    end
    done.moveInFlight = asked and (answer.locked == true or lockSeen) or (not asked and "unknown")
    local inFlight = done.moveInFlight ~= false
    local looked = asked and type(answer.looked) == "table" and answer.looked or {}
    local identity = Client:CharacterIdentity() or {}
    -- A bank of the visit whose locks could not be seen (it could not be
    -- read now, or reads as empty while items of it are remembered): a move
    -- from it into an empty carried slot is not seen on its way, and its
    -- answer may come late. The watch after the close is longer for it.
    done.unreadable = {}
    for _, kind in ipairs(BANK_KINDS) do
        local seen = looked[kind]
        if v[kind].usable and (type(seen) ~= "number" or (seen == 0 and RemembersItems(kind, identity))) then
            done.unreadable[kind] = true
        end
    end
    for _, kind in ipairs(BANK_KINDS) do
        local state = v[kind]
        -- Its last read found it empty and was not believed (emptyAt is
        -- cleared by every update of its own, and by a kept read):
        local lastReadEmpty = state.emptyAt ~= nil and not done.kept[kind]
        local remembersItems = RemembersItems(kind, identity)
        -- unsettled, but that empty read came after its last own update
        -- and what is remembered of it is empty too: what is remembered
        -- agrees with what was read - no mark for that;
        local settledByRead = lastReadEmpty and not remembersItems
        -- the evidence that it was emptied must not be thrown away while
        -- items of it are remembered: marked.
        if state.usable and ((state.unsettled and not settledByRead) or inFlight or (lastReadEmpty and remembersItems)) then
            local new, marked = MarkDoubt(kind, identity.guid, identity.region)
            if marked then
                done.doubt[kind] = true
            end
            if new then
                changed = true
            end
        end
    end
    -- Held: not unsettled, a read was owed and the closing read was not
    -- kept for it, and items of it are remembered (nothing can be counted
    -- twice from a bank that is remembered as empty).
    local anyHeld = false
    for _, kind in ipairs(BANK_KINDS) do
        local state = v[kind]
        if state.usable and not state.unsettled and not done.doubt[kind] and not done.kept[kind]
                and done.owed and RemembersItems(kind, identity) then
            done.held[kind] = true
            anyHeld = true
        end
    end
    local items, _, backpackSlots = Client:BagContents()
    local w = {
        at = GetTime(), guid = identity.guid, region = identity.region,
        watchFor = { character = done.unreadable.character and CLOSE_WATCH_BLIND or CLOSE_WATCH,
                     account = done.unreadable.account and CLOSE_WATCH_BLIND or CLOSE_WATCH },
        usable = { character = v.character.usable, account = v.account.usable },
        held = done.held,
        note = nil,
        bankUpdates = 0, bagUpdates = 0, compared = 0, owed = false, pending = false,
        done = {}, marked = {},
    }
    if backpackSlots and backpackSlots > 0 then
        -- A copy: the note is lowered as counts fall (rule 5b).
        w.note = {}
        for itemId, count in pairs(items) do w.note[itemId] = count end
    end
    watch = w
    if anyHeld then
        changed = true
        -- The second is over when this timer runs (one per close that holds
        -- a bank): the held banks count again from that moment - also for a
        -- scan later in the same frame - and a shown list is asked to redraw.
        C_Timer.After(CLOSE_WATCH, function()
            if watch ~= w then return end
            w.heldOver = true
            InvalidateFrame()
            if LazyProf.ScheduleShoppingListRefresh then
                LazyProf:ScheduleShoppingListRefresh()
            end
        end)
    end
    if changed then
        InvalidateFrame()
        if LazyProf.ScheduleShoppingListRefresh then
            LazyProf:ScheduleShoppingListRefresh()
        end
    end
end

-- The window is closing and the bank still counts as open.
function Inventory:OnBankClosing()
    if self:UsesSyndicator() then return end
    Protected("bank close", CloseVisit, self)
end

-- The bank counts as closed now: nothing is read any more.
function Inventory:OnBankClosed()
    bankClosedAt = GetTime()
    if visit and not visit.closedAt then
        visit.closedAt = bankClosedAt
        visit.owed = false
    end
end

-- What is remembered of a bank of the visit the watch follows.
local function WatchedBank(w, kind)
    if kind == "character" then
        return LazyProf.StockMemory:OwnBank(w.guid)
    end
    return LazyProf.StockMemory:AccountBank(w.region)
end

-- Rule 5: mark a bank of the visit in doubt, for `reason`. Only a bank that
-- was usable in the visit, and of which something is remembered. Returns
-- whether the mark is new.
local function WatchMark(w, kind, reason)
    if w.done[kind] or not w.usable[kind] then return false end
    local new, marked = MarkDoubt(kind, w.guid, w.region)
    if marked then
        w.done[kind] = true
    end
    if not new then return false end
    w.marked[kind] = reason
    InvalidateFrame()
    if LazyProf.ScheduleShoppingListRefresh then
        LazyProf:ScheduleShoppingListRefresh()
    end
    return true
end

-- Is there still a bank of the visit the watch could mark?
local function WatchOpen(w)
    for _, kind in ipairs(BANK_KINDS) do
        if w.usable[kind] and not w.done[kind] then return true end
    end
    return false
end

-- Rule 4, for a scan: is that bank held right now - it could not be read
-- back at the close, the timer that ends CLOSE_WATCH has not run and
-- nothing has marked it?
HeldAfterClose = function(kind)
    local w = watch
    return (w ~= nil and w.held[kind] == true and not w.done[kind] and not w.heldOver) or false
end

-- Lower a note of the carried bags to every count that has fallen.
local function LowerNote(note, items)
    for itemId, count in pairs(note) do
        local now = items[itemId] or 0
        if now < count then
            note[itemId] = now > 0 and now or nil
        end
    end
end


-- Rule 5b: the comparison that is due after an update of a carried bag
-- inside the watch. Bags that cannot be read (no backpack slots) are not
-- compared: that decides nothing and leaves the comparison due. Returns
-- whether a bank was marked.
SettleAfterClose = function()
    local w = watch
    if not w or not w.owed or not w.note then return false end
    local items, _, backpackSlots = LazyProf.Client:BagContents()
    if not backpackSlots or backpackSlots <= 0 then return false end
    w.owed = false
    w.compared = w.compared + 1
    local marked = false
    local after = (w.dueAt or GetTime()) - w.at
    for _, kind in ipairs(BANK_KINDS) do
        if w.usable[kind] and not w.done[kind] and after <= w.watchFor[kind] + CLOCK_SLACK then
            local held = WatchedBank(w, kind)
            local risen = held and RisenItem(w.note, items, held)
            if risen and WatchMark(w, kind, "carried count rose: " .. tostring(risen)) then
                marked = true
            end
        end
    end
    LowerNote(w.note, items)
    w.floor = nil     -- the scans of the next frame start from the note again
    -- A scan that left a bank out for this comparison may have been drawn:
    -- when nothing was marked the bank counts again, and nothing else would
    -- say so.
    if w.scanLeftOut then
        w.scanLeftOut = false
        if not marked then
            InvalidateFrame()
            if LazyProf.ScheduleShoppingListRefresh then
                LazyProf:ScheduleShoppingListRefresh()
            end
        end
    end
    return marked
end

-- Rule 5b, for a scan that comes before that comparison: the banks it leaves
-- out ({ [kind] = true }; nil when none), judged by the bags it has just
-- read. Nothing is marked, the note is left as it is and the comparison
-- stays due. The scans of one frame measure against a floor of their own:
-- the note, lowered by every scan to what it saw fall. Between two updates
-- of a frame a count can dip (a stack shows in neither of two carried bags,
-- or was used up) and what arrives after the dip must not be counted beside
-- the bank by the next scan - but only what has risen against the note at
-- the end of the frame is a reason for a mark.
RisenAfterClose = function(bagItems)
    local w = watch
    if not w or not w.owed or not w.note then return nil end
    local floor = w.floor
    if not floor then
        floor = {}
        for itemId, count in pairs(w.note) do floor[itemId] = count end
        w.floor = floor
    end
    local leaveOut = nil
    local after = (w.dueAt or GetTime()) - w.at
    for _, kind in ipairs(BANK_KINDS) do
        if w.usable[kind] and not w.done[kind] and after <= w.watchFor[kind] + CLOCK_SLACK then
            local held = WatchedBank(w, kind)
            if held and RisenItem(floor, bagItems, held) then
                leaveOut = leaveOut or {}
                leaveOut[kind] = true
            end
        end
    end
    LowerNote(floor, bagItems)
    if leaveOut then
        w.scanLeftOut = true
    end
    return leaveOut
end

-- Rule 5a: an update of a bank container while the bank is closed marks
-- that bank at once (the character's own, or the account bank of its
-- region), whenever it comes - unless it comes in the first LOGIN_QUIET
-- seconds of a session that has had no visit yet: the client may be loading
-- the bank's containers then, and such an update is only counted.
local function ClosedBankUpdate(kind)
    local now = GetTime()
    local counts = closedBankUpdates
    counts.count = counts.count + 1
    counts.lastAfter = bankClosedAt and (now - bankClosedAt) or nil
    local w = watch
    local inWatch = w ~= nil and now - w.at <= CLOSE_WATCH_BANK + CLOCK_SLACK
    if inWatch then
        w.bankUpdates = w.bankUpdates + 1
        w.bankLast = now - w.at
    end
    if not visitedThisSession and now - sessionStartedAt < LOGIN_QUIET then
        counts.quiet = counts.quiet + 1
        return
    end
    local identity = LazyProf.Client:CharacterIdentity() or {}
    local new, marked = MarkDoubt(kind, identity.guid, identity.region)
    if w and marked then
        w.done[kind] = true
    end
    if not new then return end
    counts.marked = counts.marked + 1
    if inWatch then
        w.marked[kind] = "bank container updated"
    end
    InvalidateFrame()
    if LazyProf.ScheduleShoppingListRefresh then
        LazyProf:ScheduleShoppingListRefresh()
    end
end

-- Rule 5b: a comparison that can no longer be made (the watch is over, or
-- the session ends, and the bags still cannot be read for it): the visit's
-- banks of which items are remembered are marked.
local function GiveUpComparison(w)
    w.owed = false
    local after = (w.dueAt or GetTime()) - w.at
    for _, kind in ipairs(BANK_KINDS) do
        local held = WatchedBank(w, kind)
        if held and next(held) ~= nil and after <= w.watchFor[kind] + CLOCK_SLACK then
            WatchMark(w, kind, "bags not readable for the comparison")
        end
    end
end

-- Rule 5b: the comparison that is due, on the next frame (one timer, a
-- pending flag) and on every frame after that while the bags cannot be read
-- for it, until the watch is over.
local function SettleSoon(w)
    if w.pending then return end
    w.pending = true
    C_Timer.After(0, function()
        w.pending = false
        if watch ~= w or not w.owed then return end
        Protected("bank close", SettleAfterClose)
        if not w.owed then return end
        if GetTime() - w.at > math.max(w.watchFor.character, w.watchFor.account) + CLOCK_SLACK then
            GiveUpComparison(w)
        else
            SettleSoon(w)
        end
    end)
end

-- Rule 5b: an update of a carried bag while the bank is closed. Inside the
-- watch after a close it asks for the comparison on the next frame; without
-- a note of the bags it marks at once each bank of the visit whose watch it
-- is inside.
local function WatchBagUpdate()
    local w = watch
    if not w then return end
    local after = GetTime() - w.at
    if after > math.max(w.watchFor.character, w.watchFor.account) + CLOCK_SLACK then return end
    w.bagUpdates = w.bagUpdates + 1
    w.bagLast = after
    if not w.note then
        for _, kind in ipairs(BANK_KINDS) do
            if after <= w.watchFor[kind] + CLOCK_SLACK then
                WatchMark(w, kind, "no note of the bags")
            end
        end
        return
    end
    if not WatchOpen(w) then return end
    w.owed = true
    w.dueAt = GetTime()
    InvalidateFrame()
    SettleSoon(w)
end

-- Rule 5c: the comparison asked for by a carried bag's update, made on the
-- next frame (one timer, a pending flag): within one frame a stack on its
-- way from one carried bag to another can show in both. Bags without
-- backpack slots by then wait for the next update (or the first save).
local function CompareSoon()
    local ls = lastSession
    if ls.comparePending then return end
    ls.comparePending = true
    C_Timer.After(0, function()
        ls.comparePending = false
        if ls.state ~= "waiting" then return end
        Protected("bag update", function()
            local items = BagsToCompare(true)
            if items then
                CompareLastSession(items)
            end
        end)
    end)
end

local function BagUpdated(self, bagId)
    local Client = LazyProf.Client
    local bankKind = Client:BankKindOfBag(bagId)
    local v = OpenVisit()
    if v then
        -- An update of a bank's own container answers the moves of it a
        -- kept read saw on their way (rule 4); the bank is unsettled from
        -- here until a read of it is kept.
        if bankKind and v[bankKind] then
            v[bankKind].lockSeen = nil
        end
        self:OnBankChange(bankKind)
    else
        if bankKind then
            -- It cannot be read now (rule 5a). Counted too, so that one dump
            -- shows whether the client reports bank changes while closed.
            ClosedBankUpdate(bankKind)
        else
            WatchBagUpdate()
        end
    end
    if not bankKind then
        -- Rule 5c: the first update of a carried bag in a session that began
        -- with a note asks for the comparison.
        if LastSession().state == "waiting" then
            CompareSoon()
        end
        self:RequestBagSave(true)
    end
end

-- A bag update (Core/Init.lua passes every BAG_UPDATE on with its container
-- id). While the bank is open the bank is read again (rule 1); an update of
-- a bank container is not a change of the bags.
function Inventory:OnBagUpdate(bagId)
    if self:UsesSyndicator() then return end
    Protected("bag update", BagUpdated, self, bagId)
end

local function BatchComplete(self)
    local v = OpenVisit()
    if not v or not v.owed then return end
    local frame = GetTime()
    if v.lastReadAt == nil or v.lastReadAt == frame or frame - v.lastReadAt >= BANK_READ_SPACING - CLOCK_SLACK then
        LookAtBank(self)
    end
end

-- The client says a batch of bag updates is complete (Core/Init.lua passes
-- BAG_UPDATE_DELAYED on): a read owed for this frame's updates is taken now.
function Inventory:OnBagUpdateDelayed()
    if self:UsesSyndicator() then return end
    Protected("bag update", BatchComplete, self)
end

-- The end of the session (rules 4 and 5c). A session that began with a note
-- and has not compared yet does so now, with bags that hold something (the
-- save below would otherwise put them beside a bank that was never doubted);
-- else the note stays for the session after. A bank that is held after the
-- close is marked. And a session that ends with the bank open or within
-- CLOSE_WATCH_BANK after a close leaves its own note, for the banks its
-- visit could use.
local function EndSession()
    local Client = LazyProf.Client
    if LastSession().state == "waiting" then
        local items = BagsToCompare(false)
        if items then
            CompareLastSession(items)
        end
    end
    local w = watch
    if not w or GetTime() - w.at > CLOSE_WATCH_BANK + CLOCK_SLACK then return end
    -- A bank that is still held (rule 4): its update can no longer be heard.
    for _, kind in ipairs(BANK_KINDS) do
        if HeldAfterClose(kind) then
            WatchMark(w, kind, "not read back before the session ended")
        end
    end
    if not (w.usable.character or w.usable.account) then return end
    local identity = Client:CharacterIdentity() or {}
    LazyProf.StockMemory:NoteBagsAtBank(identity, BagsToCompare(false) or w.note, w.usable, Client:Now())
end

-- Logout (the client's event, and the database's own shutdown notice, which
-- is sure to come before the saved tables are tidied; either may come first
-- and both may come). With the bank still open the visit ends as at a close,
-- and a comparison that is due after a close is made. A session that ends
-- at the bank leaves its note of the bags (rule 5c). Then a bag save that is
-- still waiting is written.
function Inventory:OnLogout()
    if self:UsesSyndicator() then return end
    if visit and not visit.closedAt and not visit.closing then
        Protected("logout", CloseVisit, self)
    end
    -- A comparison still due after a close (rule 5b) has no next frame to
    -- wait for: it is made now, or given up.
    if watch and watch.owed then
        Protected("logout", SettleAfterClose)
        if watch.owed then
            Protected("logout", GiveUpComparison, watch)
        end
    end
    Protected("logout", EndSession)
    if not bagSavePending then return end
    bagSavePending = false
    bagUpdateSeen = false
    Protected("logout", self.SaveBags, self, false)
end

-- Start listening (called once the addon is enabled). Characters not seen
-- for a long time are dropped here - never the one being played - and the
-- character is remembered shortly after login even if its bags never change.
-- Nothing in here can stop the addon from starting.
function Inventory:Initialize()
    sessionStartedAt = GetTime()
    visitedThisSession = false
    lastSession = { looked = false, marked = {}, started = true }
    bankClosedAt = nil
    closedBankUpdates = { count = 0, lastAfter = nil, quiet = 0, marked = 0 }
    Protected("start", function()
        LazyProf.Client:StartStock({
            onBankOpened = function() Inventory:OnBankOpened() end,
            onBankChanged = function(kind) Protected("bank read", Inventory.OnBankChange, Inventory, kind) end,
            onBankClosing = function() Inventory:OnBankClosing() end,
            onBankClosed = function() Inventory:OnBankClosed() end,
            onLogout = function() Inventory:OnLogout() end,
        })
    end)
    if self:UsesSyndicator() then return end
    Protected("start", function()
        local Client = LazyProf.Client
        local identity = Client:CharacterIdentity() or {}
        if identity.guid then
            LazyProf.StockMemory:Prune(Client:Now(), identity.guid)
        end
    end)
    self:ForgetAltsPart()
    Protected("start", LastSession)
    self:RequestBagSave()
end

-- The Self-Found setting changed: what is remembered of this character says
-- from now on whether it can send (its alts read that), and the next scan
-- starts afresh.
function Inventory:OnSendingChanged()
    self:InvalidateCache()
    if self:UsesSyndicator() then return end
    Protected("setting", function()
        local identity = LazyProf.Client:CharacterIdentity() or {}
        LazyProf.StockMemory:SetCanSend(identity.guid, CanSend())
    end)
end

-- Every setting went back to its default (the options' reset; what is
-- remembered was kept through it, see LazyProf:ResetSettings): nothing a scan
-- kept may answer any more, and the character's record says again whether it
-- can send, as the setting stands now.
function Inventory:OnSettingsReset()
    self:ForgetAltsPart()
    self:OnSendingChanged()
end

-- Forget every remembered character and account bank (the options button).
-- The character being played is remembered again by itself: its bags with
-- the next save, and its bank at once when the bank window is open.
function Inventory:ForgetRemembered()
    -- With Syndicator installed the memory is neither read nor written, by
    -- this path either (the options hide the button then).
    if self:UsesSyndicator() then return end
    LazyProf.StockMemory:Forget()
    self:InvalidateCache()
    self:ForgetAltsPart()
    watch = nil
    if lastSession.state == "waiting" then
        lastSession.state = nil       -- the note went with everything else
    end
    Protected("bank read", LookAtBank, self)
    self:RequestBagSave()
end

-- /lp diag stock: what the client itself counts of the character's
-- remembered bank, beside what is remembered - a line for each of the lowest
-- CLIENT_COUNT_ITEMS item ids of that bank (the lowest, so that two dumps
-- print the same items). Whether the client's count sees a bank while its
-- window is closed is not known; taken away from the bank, `withBank -
-- carried` equal to the remembered bank says that it does. Only the dump
-- asks for these counts. On a client whose adapter has none, no line.
local CLIENT_COUNT_ITEMS = 5

local function AddClientCounts(add, identity)
    local Memory, Client = LazyProf.StockMemory, LazyProf.Client
    -- Asked without an item, the adapter says whether this client counts at all.
    if Client:ClientItemCounts(nil) == nil then return end
    local bank = Memory:OwnBank(identity.guid) or {}
    local ids = {}
    for itemId in pairs(bank) do ids[#ids + 1] = itemId end
    if #ids == 0 then
        add("client count: nothing remembered of this bank to compare")
        return
    end
    table.sort(ids)
    local account = AccountBankOf(identity)
    local accountText = "never seen"
    if not account and Memory:AccountBank(identity.region) then
        accountText = "read in another world or by the other faction"
    end
    local carriedNow = Client:BagContents()
    for i = 1, math.min(CLIENT_COUNT_ITEMS, #ids) do
        local itemId = ids[i]
        local carried, withBank, withAccountBank = Client:ClientItemCounts(itemId)
        add("client count " .. tostring(itemId) .. ": carried=" .. tostring(carried) .. " withBank=" .. tostring(withBank)
            .. " withAccountBank=" .. tostring(withAccountBank)
            .. "; remembered: bags now=" .. tostring(carriedNow[itemId] or 0) .. " bank=" .. tostring(bank[itemId])
            .. " accountBank=" .. (account and tostring(account[itemId] or 0) or accountText))
    end
end

-- The dump's lines of the bank visit in progress or the last one, of the
-- watch after its close, of the last session's note and of the bank updates
-- that came while the bank was closed (see RunDiagnostic below).
local function AddBankVisitLines(add)
    local Client = LazyProf.Client
    local v = visit
    local bankReadWaiting = v ~= nil and not v.closedAt
        and (v.owed or v.confirm or v.trailingPending or v.repeatPending or next(v.lookPending) ~= nil) or false
    add("waiting: bagSave=" .. tostring(bagSavePending) .. " bankRead=" .. tostring(bankReadWaiting)
        .. " bankOpen=" .. tostring(Client:IsBankOpen()))
    -- The bank visit in progress or the last one: which rules fired.
    if not v then
        add("bank visit: none this session")
    else
        local frame = GetTime()
        local head
        if v.closedAt then
            head = string.format("bank visit: closed %.1f s ago after %.1f s", frame - v.closedAt, v.closedAt - v.openedAt)
        else
            head = string.format("bank visit: open for %.1f s", frame - v.openedAt)
        end
        -- How often an opening notice came again while this visit was open.
        add(head .. "; reads=" .. tostring(v.reads) .. " owed=" .. tostring(v.owed)
            .. (v.reopened and (" openedAgain=" .. tostring(v.reopened)) or ""))
        for _, kind in ipairs(BANK_KINDS) do
            local state = v[kind]
            add("bank visit " .. kind .. ": usable=" .. tostring(state.usable) .. " kept=" .. tostring(state.kept)
                .. " lastRead=" .. tostring(state.last or "none")
                .. " slots=" .. tostring(state.slots) .. " unresolvedEmpty=" .. tostring(state.emptyAt ~= nil)
                .. " unsettled=" .. tostring(state.unsettled))
        end
        local done = v.closing
        if done then
            local function names(set)
                local list = {}
                for _, kind in ipairs(BANK_KINDS) do
                    if set[kind] then list[#list + 1] = kind end
                end
                return #list > 0 and table.concat(list, ",") or "none"
            end
            add("bank visit close: owed=" .. tostring(done.owed) .. " unsettled=" .. names(done.unsettled)
                .. " readAgain=" .. tostring(done.read) .. " kept=" .. names(done.kept)
                .. " markedInDoubt=" .. names(done.doubt) .. " held=" .. names(done.held)
                .. " moveInFlight=" .. tostring(done.moveInFlight)
                .. (next(done.unreadable or {}) and (" unreadable=" .. names(done.unreadable)) or ""))
        end
    end
    -- The watch after the last close: what arrived, and which banks it
    -- marked and why.
    if watch then
        local function updates(label, count, last)
            return label .. "=" .. tostring(count) .. (last and string.format(" (last %.1f s after the close)", last) or "")
        end
        local marks = {}
        for _, kind in ipairs(BANK_KINDS) do
            if watch.marked[kind] then
                marks[#marks + 1] = kind .. " (" .. watch.marked[kind] .. ")"
            end
        end
        add("after the close: " .. updates("bankUpdates", watch.bankUpdates, watch.bankLast)
            .. " " .. updates("bagUpdates", watch.bagUpdates, watch.bagLast)
            .. " compared=" .. tostring(watch.compared)
            .. " marked=" .. (#marks > 0 and table.concat(marks, ", ") or "none"))
    end
    -- The note the character's last session left at the bank, and what the
    -- comparison with this session's bags gave (rule 5c).
    if lastSession.state then
        local damagedText = lastSession.fromRecord and " (the record's time is damaged)" or " (the note's time is damaged)"
        local marks = {}
        for _, kind in ipairs(BANK_KINDS) do
            if lastSession.marked[kind] then marks[#marks + 1] = kind end
        end
        local banks = (#marks > 0 and table.concat(marks, ",") or "none") .. " marked in doubt"
        local newer = {}
        for _, kind in ipairs(BANK_KINDS) do
            if lastSession.newer and lastSession.newer[kind] then newer[#newer + 1] = kind end
        end
        if #newer > 0 then
            banks = banks .. "; " .. table.concat(newer, ",") .. " read since the note, not marked"
        end
        local notRisen = {}
        for _, kind in ipairs(BANK_KINDS) do
            if lastSession.notRisen and lastSession.notRisen[kind] then notRisen[#notRisen + 1] = kind end
        end
        if #notRisen > 0 then
            banks = banks .. "; " .. table.concat(notRisen, ",") .. " not marked (nothing it holds rose)"
        end
        local said = {
            waiting = "not compared yet",
            equal = "compared, equal",
            different = "compared, different: " .. banks,
            unknown = "unknown" .. (lastSession.damaged and damagedText or "") .. ": " .. banks,
        }
        local label = lastSession.fromRecord and "bags as last saved (no note from the last session)"
            or "bags at the bank (from the last session)"
        add(label .. ": " .. said[lastSession.state])
    end
    -- Whether the client reports bank changes while the window is closed
    -- (they cannot be read then), when, and what they did (rule 5a).
    local closedLine = "bank updates while closed: " .. tostring(closedBankUpdates.count)
    if closedBankUpdates.count > 0 then
        if closedBankUpdates.lastAfter then
            closedLine = closedLine .. string.format(", last %.1f s after closing", closedBankUpdates.lastAfter)
        else
            closedLine = closedLine .. ", before the bank was opened this session"
        end
        closedLine = closedLine .. " (in the first " .. tostring(LOGIN_QUIET) .. " s of the session, only counted: "
            .. tostring(closedBankUpdates.quiet) .. "; marked a bank in doubt: " .. tostring(closedBankUpdates.marked) .. ")"
    end
    add(closedLine)
end

-- /lp diag stock: where stock outside the bags comes from, who the character
-- is, what the current or the last bank visit did, what the client itself
-- counts of the remembered bank and what is remembered.
-- Read-only (an open bank is neither read nor saved by it).
function Inventory:RunDiagnostic(lines)
    local function add(text) lines[#lines + 1] = text end
    local Memory, Client = LazyProf.StockMemory, LazyProf.Client
    local profile = LazyProf.db.profile
    local usesSyndicator = self:UsesSyndicator()

    if usesSyndicator then
        add("source: Syndicator (LazyProf's own memory is not used and not updated)")
    else
        add("source: LazyProf's own memory (Syndicator is not installed)")
    end
    -- The Self-Found setting and the game's own flag, apart: either makes
    -- the character Self-Found for stock. The flag is asked here without
    -- counting a failure (the dump reports, it does not add to the count).
    local flagRead, gameFlag = pcall(Client.IsSelfFoundCharacter, Client)
    local selfFound = SelfFoundSetting() or (flagRead and gameFlag == true)
    add("settings: bank=" .. tostring(profile.includeBankItems) .. " alts=" .. tostring(profile.includeAltCharacters)
        .. " guildBank=" .. tostring(profile.includeGuildBank) .. " selfFound=" .. tostring(SelfFoundSetting())
        .. " gameSelfFound=" .. (flagRead and tostring(gameFlag == true) or ("not readable: " .. tostring(gameFlag))))

    if memoryErrors.count > 0 then
        add("last error: " .. tostring(memoryErrors.last) .. " (in: " .. tostring(memoryErrors.where) .. "; "
            .. tostring(memoryErrors.count) .. " this session; the first was handed to the game's error display)")
    end
    -- What a scan does right now: tried here, on tables that are thrown
    -- away, so that a failure long over does not read as stock left out.
    -- The line says only what was tried - that the memory reads. Which of
    -- its stock counts is said by the settings line and by each character's
    -- label (with bank items and alts off, or on a client without a bank,
    -- nothing of it may count at all).
    if not usesSyndicator then
        local whole, err = pcall(AddRememberedStock, self, {}, {}, profile.includeAltCharacters and not selfFound, selfFound)
        if whole then
            add("scan now: the memory reads without error")
        else
            add("scan now: bags only - the memory cannot be read: " .. tostring(err))
        end
    end

    -- Who the character is may be the very call that fails: the rest of the
    -- dump is still worth having.
    local identityRead, identity = pcall(Client.CharacterIdentity, Client)
    if not identityRead then
        add("identity: could not be read: " .. tostring(identity))
        identity = {}
    end
    identity = identity or {}
    local now = Client:Now()
    add("identity: guid=" .. tostring(identity.guid) .. " name=" .. tostring(identity.name)
        .. " world=" .. tostring(identity.world) .. " faction=" .. tostring(identity.faction)
        .. " region=" .. tostring(identity.region))
    -- What the world and the faction decide is which remembered stock
    -- counts: nothing of the memory counts with Syndicator installed.
    if not usesSyndicator and not identity.world then
        add("world: unknown - alts and the account bank are not counted")
    end
    if not usesSyndicator and not identity.faction then
        add("faction: unknown - alts are not counted")
    end
    -- The bank visits are followed only without Syndicator, and only where
    -- the adapter reads the bank at all; elsewhere one line says so in place
    -- of the visit's lines.
    if usesSyndicator then
        add("bank: not followed (Syndicator is installed)")
    elseif not Client:ReadsBank() then
        add("waiting: bagSave=" .. tostring(bagSavePending))
        add("bank: not followed on this client")
    else
        AddBankVisitLines(add)
    end

    -- What the client itself counts of the remembered bank (not with
    -- Syndicator: the memory is not in use then). A section of its own: a
    -- count call that fails is said here, and the rest of the dump stays.
    if not usesSyndicator then
        local counted, countError = pcall(AddClientCounts, add, identity)
        if not counted then
            add("SECTION ERROR: client count: " .. tostring(countError))
        end
    end

    local summary = Memory:Summary(now)
    if not summary.usable then
        add("memory: format=" .. tostring(summary.schema) .. " - not a format this version reads; it is left alone")
        return
    end
    -- Old characters are dropped at the start of a session that uses the
    -- memory. With Syndicator installed none is, so the line leaves that out.
    add("memory: format=" .. tostring(summary.schema) .. " characters=" .. tostring(#summary.characters)
        .. " accountBanks=" .. tostring(#summary.account)
        .. (usesSyndicator and "" or (" (characters not seen for " .. tostring(Memory.KEEP_DAYS) .. " days are dropped)")))
    if summary.unreadable > 0 then
        add("memory: unreadable=" .. tostring(summary.unreadable)
            .. " (saved entries that are not what LazyProf writes; they are skipped, and Forget remembered characters removes them)")
    end

    -- What happens to each character's stock, and why.
    local STANDING = {
        self = "this character",
        world = "other world",
        faction = "other faction",
        nosend = "not counted (Self-Found)",
        noname = "not counted (no name)",
        name = "not counted (an older record of this name)",
        unseen = "not counted (no time it was last seen)",
        unknown = "not counted (this character's world or faction is unknown)",
    }
    local standing = Memory:Standing(identity)
    local function part(label, items, at, doubt, damaged)
        if items == nil then return label .. "=never seen" end
        if damaged then return label .. "=" .. tostring(items) .. " items (time damaged: not counted)" end
        return label .. "=" .. tostring(items) .. " items (" .. tostring(Memory.AgeText(now, at) or "no time")
            .. (doubt and ", in doubt: not counted" or "") .. ")"
    end
    for _, c in ipairs(summary.characters) do
        local label = STANDING[standing[c.guid]]
        if usesSyndicator then
            -- Left over from a time without it: listed, but nothing of it counts.
            label = "remembered, not used (Syndicator is installed)"
        elseif standing[c.guid] == "alt" then
            if selfFound then
                label = "not counted (this character is Self-Found)"
            elseif not profile.includeAltCharacters then
                label = "alt, not counted (alts off)"
            elseif not profile.includeBankItems then
                label = "alt, counted (bags only: bank items are off)"
            else
                label = "alt, counted"
            end
        end
        add("character: " .. tostring(c.name) .. " [" .. tostring(label) .. "] world=" .. tostring(c.world)
            .. " faction=" .. tostring(c.faction) .. " " .. part("bags", c.bagItems, c.bagsAt, false, c.bagsDamaged)
            .. " " .. part("bank", c.bankItems, c.bankAt, c.bankDoubt, c.bankDamaged) .. " guid=" .. tostring(c.guid))
    end
    -- The account bank of each region: whose read it is, and whether it
    -- counts for this character (only for the world and faction of that
    -- read, only while bank items count, and not for a Self-Found character).
    for _, bank in ipairs(summary.account) do
        local here = bank.region == identity.region and identity.world ~= nil and bank.world == identity.world
            and bank.faction == identity.faction
        local counts
        if usesSyndicator then
            counts = "remembered, not used (Syndicator is installed)"
        elseif bank.region ~= identity.region then
            counts = "not counted (another region)"
        elseif not here then
            counts = "not counted (read in another world or by the other faction)"
        elseif not profile.includeBankItems then
            counts = "not counted (bank items are off)"
        elseif selfFound then
            counts = "not counted (this character is Self-Found)"
        elseif bank.doubt then
            counts = "not counted (in doubt)"
        elseif bank.damaged then
            counts = "not counted (its time is damaged)"
        else
            counts = "counted"
        end
        local age
        if bank.damaged then
            age = "time damaged: not counted"
        else
            age = tostring(Memory.AgeText(now, bank.at) or "no time") .. (bank.doubt and ", in doubt: not counted" or "")
        end
        add("account bank: region=" .. tostring(bank.region) .. " read by world=" .. tostring(bank.world)
            .. " faction=" .. tostring(bank.faction) .. " items=" .. tostring(bank.items) .. " (" .. age .. ")"
            .. " - " .. counts)
    end
end

-- ============================================================================
-- Utility methods
-- ============================================================================

-- Get count of specific item in bags
function Inventory:GetItemCount(itemId)
    local items = self:ScanBags()
    return items[itemId] or 0
end

-- Check if we have enough materials for a recipe
function Inventory:HasMaterials(recipe, inventory)
    inventory = inventory or self:ScanBags()

    for _, reagent in ipairs(recipe.reagents) do
        local have = inventory[reagent.itemId] or 0
        if have < reagent.count then
            return false
        end
    end
    return true
end

-- Get missing materials for a recipe (quantity needed - quantity owned)
function Inventory:GetMissingMaterials(recipe, quantity, inventory)
    inventory = inventory or self:ScanBags()
    local missing = {}

    for _, reagent in ipairs(recipe.reagents) do
        local have = inventory[reagent.itemId] or 0
        local need = reagent.count * quantity
        local short = math.max(0, need - have)

        if short > 0 then
            table.insert(missing, {
                itemId = reagent.itemId,
                have = have,
                need = need,
                missing = short,
            })
        end
    end

    return missing
end
