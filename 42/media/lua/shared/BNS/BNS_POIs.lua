--***********************************************************************
-- Bandits & Survivors — points of interest eligible for fortification
--
-- World coordinates for well-known Knox Country locations. Each entry
-- gives a centre square and a radius: windows/doors within the radius
-- are barricaded, containers stocked, and militia defenders posted.
--***********************************************************************

require "BNS/BNS_Core"

BNS.POIs = {
    { name = "Rosewood Fire Station",     x = 8069,  y = 11753, z = 0, radius = 14 },
    { name = "Rosewood Gas Station",      x = 8148,  y = 11416, z = 0, radius = 10 },
    { name = "Muldraugh Warehouse",       x = 10756, y = 9316,  z = 0, radius = 16 },
    { name = "Muldraugh Gas 'N Go",       x = 10603, y = 10286, z = 0, radius = 10 },
    { name = "West Point Gun Store",      x = 11957, y = 6863,  z = 0, radius = 10 },
    { name = "West Point Food Market",    x = 12061, y = 6803,  z = 0, radius = 12 },
    { name = "Riverside Storage Lots",    x = 6539,  y = 5347,  z = 0, radius = 14 },
    { name = "Riverside Gas Station",     x = 6415,  y = 5290,  z = 0, radius = 10 },
    { name = "March Ridge Community Ctr", x = 10121, y = 12766, z = 0, radius = 14 },
    { name = "Fallas Lake Cabins",        x = 7176,  y = 8563,  z = 0, radius = 12 },
    { name = "Dixie Trailer Park",        x = 10919, y = 10102, z = 0, radius = 12 },
    { name = "Valley Station Mall Lot",   x = 12876, y = 4954,  z = 0, radius = 16 },
}

-- Military sites: bandit spawns near these lean heavily ex-military,
-- fading out to the given radius (tiles). Coordinates are approximate
-- centres of the vanilla Knox Country military locations — adjust or
-- extend freely (map mods can just append to this table).
BNS.MilitaryZones = {
    { name = "Secret Military Base",           x = 4432,  y = 10786, radius = 600 },
    { name = "Louisville Military Blockade",   x = 12650, y = 2100,  radius = 400 },
    { name = "Valley Station Hwy Checkpoint",  x = 13860, y = 5430,  radius = 350 },
    { name = "Knox Bridge Checkpoint",         x = 9250,  y = 7200,  radius = 300 },
}
