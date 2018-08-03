<%@ Page Language="c#" %>
<%@ Import Namespace="System.Data" %>
<%@ Import Namespace="System.Data.SqlClient" %>

<HTML>
    <BODY>
            <% Response.Write("DOMAIN\\USERNAME: " + User.Identity.Name); %>
            <br><br>
            <%
                SqlConnection sql1 = new SqlConnection("Data Source=mySQLserver.local;Initial Catalog=TestDB;Integrated Security=True;MultipleActiveResultSets=True");
                SqlCommand cmd = new SqlCommand();
                SqlDataReader reader;

                cmd.CommandText = "SELECT col1,col2 FROM table1";
                cmd.CommandType = CommandType.Text;
                cmd.Connection = sql1;

                Response.Write(cmd.CommandText);
                Response.Write("<br>");

                sql1.Open();
                reader = cmd.ExecuteReader();
                    while (reader.Read()) {
                        Response.Write(reader.GetString(0));
                        Response.Write(" ");
                        Response.Write(reader.GetString(1));
                        Response.Write("<br>");
                    }
                reader.Close();
                sql1.Close();
            %>
    </BODY>
</HTML>
