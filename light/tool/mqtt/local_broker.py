import asyncio

from amqtt.broker import Broker


async def main():
    # 无账号测试服务仅绑定本机回环地址
    broker = Broker({
        "listeners": {"default": {"type": "tcp", "bind": "127.0.0.1:18883"}},
        "plugins": {"amqtt.plugins.authentication.AnonymousAuthPlugin": {"allow_anonymous": True}},
    })
    await broker.start()
    print("本机 MQTT 测试服务已启动：127.0.0.1:18883", flush=True)
    try:
        await asyncio.Future()
    finally:
        await broker.shutdown()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
