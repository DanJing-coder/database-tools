# -*- coding: UTF-8 -*-
import pymysql

class DbHanlder():
    def __init__(self, user, passwd="", db="", host="localhost", port=9030):
        self.host = host
        self.user = user
        self.passwd = passwd
        self.port = port
        self.dbName = db
        self.charset = "utf8"

    def open(self):
        try:
            conn = pymysql.connect(
                host=self.host,
                user=self.user,
                password=self.passwd,
                db=self.dbName,
                port=self.port,
                charset=self.charset,
            )
        except pymysql.err.OperationalError as e:
            print("connect failed")
            if "Errno 10060" in str(e) or "2003" in str(e):
                print("connect failed")
            raise
        print("connect successful")
        self.currentConn = conn
        self.cursor = self.currentConn.cursor()

    def close(self):
        print("close connection")
        if self.cursor:
            self.cursor.close()
        self.currentConn.close()

    def query(self, sql):
        data = ()
        try:
            self.cursor.execute(sql)
            data = self.cursor.fetchall()
            fields = self.cursor.description
        except Exception as e:
            print(e)
        return (fields, data)

    def query_many(self, sql):
        data = ()
        try:
            self.cursor.executemany(sql)
            data = self.cursor.fetchmany()
        except Exception as e:
            self.currentConn.rollback()
            print(e)
        return data


    def insert(self, sql):
        try:
            self.cursor.execute(sql)
            self.currentConn.commit()
        except Exception as e:
            self.currentConn.rollback()
            print(e)
        self.close()

    def format(self, fields, result):
        data = []
        fields = [itr[0] for itr in fields]
        result = [list(itr) for itr in result]
        for row in result:
            data.append(dict(zip(fields, row)))
        return data

if __name__ == "__main__":
    DBHandler = DbHanlder(host="127.0.0.1", port=9030, user="root", passwd="", db="information_schema")
    DBHandler.open()
    print(DBHandler.query("select * from information_schema.tables limit 1"))
