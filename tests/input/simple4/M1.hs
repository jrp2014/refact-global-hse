-- Test moving s2 to a place that imports it
module M1
    ( s1
    , s2
    ) where

s1 :: Int
s1 = 1

s2 :: Int
s2 = s1 + 1
