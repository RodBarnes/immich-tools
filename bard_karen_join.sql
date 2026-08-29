CREATE TEMP TABLE bard_paths (path text);
\copy bard_paths FROM '/tmp/bard_karen_paths.txt'
SELECT COUNT(*) FROM asset a JOIN bard_paths b ON a."originalPath" = b.path WHERE a."ownerId" = '6c7abd53-aac9-43fa-a607-ac3f3e205d2d';
\copy (SELECT a.id FROM asset a JOIN bard_paths b ON a."originalPath" = b.path WHERE a."ownerId" = '6c7abd53-aac9-43fa-a607-ac3f3e205d2d') TO '/tmp/bard_karen_asset_ids.txt'
