-- Add Carpet Cleaning service category
INSERT INTO services (name, search_aliases)
SELECT 'Carpet Cleaning', '{"carpet clean", "carpet shampoo", "steam cleaning", "rug cleaning", "carpet care"}'
WHERE NOT EXISTS (SELECT 1 FROM services WHERE name = 'Carpet Cleaning');
