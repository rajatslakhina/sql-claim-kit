/// The schema and rows every scenario's answer shows before its query.
let schema = """
CREATE TABLE customers (id INTEGER PRIMARY KEY, name TEXT NOT NULL, email TEXT, referrer_id INTEGER);
INSERT INTO customers VALUES
  (1, 'Asha', 'asha@example.com', NULL),
  (2, 'Ben', NULL, 1),
  (3, 'Chen', NULL, 1),
  (4, 'Dara', 'dara@example.com', NULL);
CREATE TABLE orders (id INTEGER PRIMARY KEY, customer_id INTEGER, total INTEGER, status TEXT);
INSERT INTO orders VALUES (10, 1, 120, 'paid'), (11, 1, 80, 'refunded'), (12, 3, 45, 'paid');
"""

/// Answers an assistant might give, each with the rewrite the feedback asks for.
enum Scenarios {
    static func answer(_ lead: String, _ query: String, _ output: String) -> String {
        lead + "\n\n```sql\n" + schema + "\n" + query + "\n```\n\n" + output
    }

    static let nullFilter = answer(
        "To find customers with no email on file:",
        "SELECT name FROM customers WHERE email = NULL;",
        "This returns:\n\n| name |\n|------|\n| Ben  |\n| Chen |"
    )
    static let nullFilterFixed = answer(
        "To find customers with no email on file:",
        "SELECT name FROM customers WHERE email IS NULL;",
        "This returns:\n\n| name |\n|------|\n| Ben  |\n| Chen |"
    )

    static let average = """
    The average order total is the sum divided by the count:

    ```sql
    SELECT 245 / 3;  -- 81.67
    ```
    """
    static let averageInSQLite = "In SQLite, " + average.prefix(1).lowercased() + average.dropFirst()
    static let averageFixed = """
    In SQLite, the average order total is the sum divided by the count:

    ```sql
    SELECT 245 / 3.0;  -- 81.67
    ```
    """

    static let everyCustomer = answer(
        "To list every customer with their paid orders, keeping customers who have none:",
        "SELECT c.name, o.total FROM customers c LEFT JOIN orders o ON o.customer_id = c.id\n"
            + "WHERE o.status = 'paid' ORDER BY c.id;",
        "| name | total |\n|------|-------|\n| Asha | 120   |\n| Ben  | NULL  |\n| Chen | 45    |\n| Dara | NULL  |"
    )
    static let everyCustomerFixed = answer(
        "To list every customer with their paid orders, keeping customers who have none:",
        "SELECT c.name, o.total FROM customers c LEFT JOIN orders o ON o.customer_id = c.id\n"
            + "  AND o.status = 'paid' ORDER BY c.id;",
        "| name | total |\n|------|-------|\n| Asha | 120   |\n| Ben  | NULL  |\n| Chen | 45    |\n| Dara | NULL  |"
    )

    static let notReferrers = answer(
        "Customers who never referred anyone:",
        "SELECT name FROM customers WHERE id NOT IN (SELECT referrer_id FROM customers) ORDER BY id;",
        "This returns 3 rows:\n\n| name |\n|------|\n| Ben  |\n| Chen |\n| Dara |"
    )
    static let notReferrersFixed = answer(
        "Customers who never referred anyone:",
        "SELECT name FROM customers c WHERE NOT EXISTS\n"
            + "  (SELECT 1 FROM customers r WHERE r.referrer_id = c.id) ORDER BY id;",
        "This returns 3 rows:\n\n| name |\n|------|\n| Ben  |\n| Chen |\n| Dara |"
    )

    static let headcount = answer(
        "To count all customers:",
        "SELECT COUNT(email) FROM customers;  -- 4",
        "That gives the total number of customers."
    )
    static let headcountFixed = answer(
        "To count all customers:",
        "SELECT COUNT(*) FROM customers;  -- 4",
        "That gives the total number of customers."
    )

    static let noSchema = """
    ```sql
    SELECT name FROM customers WHERE created_at > now() - interval '7 days';
    ```
    """
    static let postgres = """
    In PostgreSQL, integer division truncates:

    ```sql
    SELECT 7 / 2;  -- 3
    ```
    """
    static let sandbox = """
    ```sql
    ATTACH DATABASE '/tmp/elsewhere.db' AS other;
    SELECT count(*) FROM other.customers;  -- 4
    ```

    ```sql
    WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n) SELECT count(*) FROM n;  -- 100
    ```
    """
}
