"""One functional order/payment check, not a load test."""
import argparse
import json
import re
import time
import sys
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def request_json(method, url, payload=None):
    body = json.dumps(payload).encode('utf-8') if payload is not None else None
    headers = {'Content-Type': 'application/json'} if body is not None else {}
    try:
        with urlopen(Request(url, data=body, headers=headers, method=method), timeout=15) as response:
            data = json.load(response)
    except HTTPError as exc:
        detail = exc.read().decode('utf-8', errors='replace')[:500]
        raise RuntimeError(f"{method} {url}: HTTP {exc.code}: {detail}") from exc
    require(isinstance(data, dict), f"{url}: expected a JSON object")
    require("error" not in data, f"{url}: {data}")
    return data


def wait_ready(url):
    deadline = time.monotonic() + 60
    last_error = "not ready"
    while time.monotonic() < deadline:
        try:
            with urlopen(url, timeout=5) as response:
                if response.status == 200:
                    return
                last_error = f"HTTP {response.status}"
        except (URLError, OSError) as exc:
            last_error = str(exc)
        time.sleep(2)
    raise RuntimeError(f"Readiness failed for {url}: {last_error}")


def is_paid(value):
    return value is True or (isinstance(value, str) and value.lower() == "true")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--store", default="http://store_manager:5000")
    parser.add_argument("--payment", default="http://payments_api:5009")
    parser.add_argument("--gateway", default="http://api-gateway:8080")
    args = parser.parse_args()

    wait_ready(args.store + "/health-check")
    wait_ready(args.payment + "/")
    wait_ready(args.gateway + "/__health")

    created = request_json("POST", args.gateway + "/store-manager-api/orders", payload={
        "user_id": 1,
        "items": [{"product_id": 1, "quantity": 1}],
    })
    order_id = created.get("order_id")
    require(isinstance(order_id, int) and order_id > 0, f"Invalid order_id: {created}")
    order = request_json("GET", f"{args.store}/orders/{order_id}")
    match = re.search(r"/payments-api/payments/process/(\d+)$", order.get("payment_link", ""))
    require(match is not None, f"Invalid payment link: {order}")
    payment_id = int(match.group(1))
    require(payment_id > 0, "The order contains payment_id 0; payment creation failed")

    before = request_json("GET", f"{args.payment}/payments/{payment_id}")
    require(before.get("order_id") == order_id, "Payment belongs to another order")
    require(before.get("is_paid") is False, "A new payment must initially be unpaid")

    processed = request_json("POST", f"{args.gateway}/payments-api/payments/process/{payment_id}", payload={
        "cardNumber": 9999999999999,
        "cardCode": 123,
        "expirationDate": "2030-01-05",
    })
    require(processed.get("order_id") == order_id, "Processed order_id does not match")
    require(processed.get("payment_id") == payment_id, "Processed payment_id does not match")
    require(is_paid(processed.get("is_paid")), "Payment processing did not succeed")

    after_payment = request_json("GET", f"{args.payment}/payments/{payment_id}")
    after_order = request_json("GET", f"{args.store}/orders/{order_id}")
    require(is_paid(after_payment.get("is_paid")), "Payment was not persisted as paid")
    require(is_paid(after_order.get("is_paid")), "Callback failed: Store Manager order is not paid")
    print(json.dumps({
        "result": "PASS", "order_id": order_id, "payment_id": payment_id,
        "payment_is_paid": True, "order_is_paid": True,
    }), flush=True)


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"Functional check FAILED: {exc}", file=sys.stderr, flush=True)
        sys.exit(1)
